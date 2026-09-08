// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IManagerRegistry.sol";

/// @title LeagueBonus
/// @notice USDC bonus paid per league, sized at that league. Each league is paid **at most once per
/// wallet, ever** — the leagues are independent of each other, and there is no ordering rule. A
/// wallet that reached Diamond first can still be paid for Gold later; a wallet already paid for
/// Gold can never be paid for Gold again, whatever happened in between.
contract LeagueBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice `None` is the reserved zero member — not a league, only an invalid input that every
    /// entry point rejects. Real leagues start at 1. A wallet that was never paid is an empty
    /// `paidLeaguesMask`, not `None`.
    enum League {
        None,
        Bronze,
        Silver,
        Gold,
        Diamond
    }

    IERC20 public usdc;
    IManagerRegistry public managerRegistry;

    /// @notice Bonus for a league, e.g. bonusAmount[League.Silver] = 30 * 1e6 for 30 USDC. Zero
    /// means "this league is not paid" — the initial state for any league whose amount is still
    /// pending business input.
    mapping(League => uint256) public bonusAmount;

    bool public killSwitch;

    /// @notice Bit set of leagues this wallet has already been paid for: bit `n - 1` corresponds to
    /// the league with ordinal `n`, so Bronze is bit 0 and Diamond is bit 3. One slot and one read
    /// per wallet, and the whole payment history of a wallet is a single number the backend can
    /// read in one call.
    mapping(address => uint256) public paidLeaguesMask;

    uint256 public totalPaid;
    uint256 public totalBonusCount;

    /// @notice Per-league totals, so the obligation volume can be read per league on-chain.
    mapping(League => uint256) public leaguePaid;
    mapping(League => uint256) public leagueBonusCount;

    event BonusSent(address indexed user, League indexed league, uint256 amount);
    event KillSwitchSet(bool enabled);
    event BonusAmountSet(League indexed league, uint256 amount);
    event ContractsUpdated(address managerRegistry, address usdc);
    event Withdrawn(address token, uint256 amount, address recipient);

    modifier onlyOperator() {
        require(managerRegistry.isOperator(msg.sender), "Not an operator");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _managerRegistry,
        address _usdc,
        uint256[] calldata _bonusAmounts // one per real league, in ordinal order; zero = not paid
    ) public initializer {
        require(_managerRegistry != address(0), "Invalid managerRegistry");
        require(_usdc != address(0), "Invalid usdc");

        // One amount per real league, derived from the enum itself: a member added to `League`
        // makes a stale deploy argument fail loudly here instead of leaving the new league
        // unconfigured (too few) or silently dropping an amount (too many).
        uint256 leagueCount = uint256(type(League).max);
        require(_bonusAmounts.length == leagueCount, "Bad amounts length");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        usdc = IERC20(_usdc);

        for (uint256 i = 0; i < leagueCount; i++) {
            // + 1 skips the reserved None member, so index 0 is Bronze
            League league = League(i + 1);
            bonusAmount[league] = _bonusAmounts[i];
            emit BonusAmountSet(league, _bonusAmounts[i]);
        }
    }

    /// @notice Pay the bonus for one league. Reverts if this wallet was already paid for that
    /// exact league — other leagues, higher or lower, do not matter.
    /// @param _user User wallet address
    /// @param _league League this payout is for
    function sendBonus(address _user, League _league) external onlyOperator nonReentrant {
        _sendBonus(_user, _league);
    }

    /// @notice Batch version. All-or-nothing: one entry that does not qualify reverts the whole
    /// batch, with a message naming the reason — `Invalid league`, `League not configured` or
    /// `League already paid`. The backend must therefore filter entries with `qualifiesForBonus`
    /// before submitting.
    /// @dev The same wallet may legitimately appear several times with different leagues; entries
    /// are applied in order, so a duplicate (wallet, league) pair inside one batch reverts on the
    /// second occurrence.
    /// @param _users Array of user wallet addresses
    /// @param _leagues Array of leagues, one per user
    function sendBonusBatch(
        address[] calldata _users,
        League[] calldata _leagues
    ) external onlyOperator nonReentrant {
        require(_users.length == _leagues.length, "Length mismatch");
        require(_users.length > 0, "Empty array");
        require(_users.length <= 200, "Too many users");

        for (uint256 i = 0; i < _users.length; i++) {
            _sendBonus(_users[i], _leagues[i]);
        }
    }

    /// @dev Bit for a real league. `None` has no bit and must be rejected before calling.
    function _bit(League _league) private pure returns (uint256) {
        return 1 << (uint256(uint8(_league)) - 1);
    }

    /// @dev Whether this wallet already consumed this league. `None` has no bit and is rejected by
    /// the caller.
    function _isPaid(address _user, League _league) internal view returns (bool) {
        return (paidLeaguesMask[_user] & _bit(_league)) != 0;
    }

    function _sendBonus(address _user, League _league) internal {
        require(!killSwitch, "Kill switch is active");
        require(_user != address(0), "Invalid address");
        require(_league != League.None, "Invalid league");
        // Split so a rejected batch entry says which of the two reasons applies — with 200 entries
        // per call, "configure the amount" and "already paid" lead to very different fixes.
        require(bonusAmount[_league] > 0, "League not configured");
        require(!_isPaid(_user, _league), "League already paid");

        uint256 amount = bonusAmount[_league];
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient USDC balance");

        paidLeaguesMask[_user] |= _bit(_league);
        totalPaid += amount;
        totalBonusCount++;
        leaguePaid[_league] += amount;
        leagueBonusCount[_league]++;

        usdc.safeTransfer(_user, amount);
        emit BonusSent(_user, _league, amount);
    }

    // --- Admin functions ---

    function setKillSwitch(bool _enabled) external onlyOwner {
        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    /// @notice Set the bonus amount for a single league. Zero is allowed and means "this league is
    /// not paid" — a payout for such a league reverts. `None` is rejected: it is not a league, so an
    /// amount for it would be dead config.
    function setBonusAmount(League _league, uint256 _amount) external onlyOwner {
        require(_league != League.None, "Invalid league");
        bonusAmount[_league] = _amount;
        emit BonusAmountSet(_league, _amount);
    }

    function updateContracts(address _managerRegistry, address _usdc) external onlyOwner {
        if (_managerRegistry != address(0)) managerRegistry = IManagerRegistry(_managerRegistry);
        if (_usdc != address(0)) usdc = IERC20(_usdc);
        // Emit the effective addresses, not the (possibly zero) arguments, so indexers can trust the event.
        emit ContractsUpdated(address(managerRegistry), address(usdc));
    }

    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        IERC20(_token).safeTransfer(_recipient, _amount);

        emit Withdrawn(_token, _amount, _recipient);
    }

    // --- View functions ---

    /// @notice Get stats for admin dashboard
    function getStats() external view returns (uint256 paid, uint256 count, uint256 balance) {
        return (totalPaid, totalBonusCount, usdc.balanceOf(address(this)));
    }

    /// @notice Per-league paid amount and payout count
    function getLeagueStats(League _league) external view returns (uint256 paid, uint256 count) {
        return (leaguePaid[_league], leagueBonusCount[_league]);
    }

    /// @notice Whether this wallet was already paid for this exact league
    function isLeaguePaid(address _user, League _league) external view returns (bool) {
        if (_league == League.None) return false;
        return _isPaid(_user, _league);
    }

    /// @notice Whether a (user, league) pair currently qualifies for a payout — the league has not
    /// been paid to this wallet before and has a non-zero amount configured
    function qualifiesForBonus(address _user, League _league) external view returns (bool) {
        if (_league == League.None) return false;
        return bonusAmount[_league] > 0 && !_isPaid(_user, _league);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
