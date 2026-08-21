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
/// @notice USDC bonus paid per league promotion, sized at the destination league. A wallet can be
/// paid several times, but only ever for a league strictly higher than the highest one it was
/// already paid for — that blocks re-payment after a demotion, and means a multi-league jump pays
/// once, for the destination only. Which transition counts as a promotion is decided off-chain by the backend;
/// this contract trusts the (user, league) pair it is given.
/// @dev The amount is read at payout time, so changing it affects vouchers already issued.
contract LeagueBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice `None` is the reserved zero member: it is not a league, it is the "no bonus paid
    /// yet" state. Real leagues start at 1.
    enum League {
        None,
        Bronze,
        Silver,
        Gold,
        Diamond
    }

    IERC20 public usdc;
    IManagerRegistry public managerRegistry;

    /// @notice Bonus per destination league, e.g. bonusAmount[League.Silver] = 30 * 1e6 for 30
    /// USDC. Zero means "promotions into this league are not paid" — the initial state for any
    /// league whose amount is still pending business input.
    mapping(League => uint256) public bonusAmount;

    bool public killSwitch;

    /// @notice Highest league this wallet has already been paid a bonus for, or `None` if it was
    /// never paid. A new payout is allowed only for a strictly higher league.
    mapping(address => League) public highestBonusedLeague;

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

    modifier onlyManager() {
        require(managerRegistry.isManager(msg.sender), "Not a manager");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _managerRegistry,
        address _usdc,
        uint256[] calldata _bonusAmounts // [Bronze, Silver, Gold, Diamond], zero = not paid
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

    /// @notice Pay the promotion bonus for a single promotion event, sized at its destination
    /// league. Reverts if this wallet was already paid for that league or a higher one.
    /// @param _user User wallet address
    /// @param _league Destination league of this specific promotion event
    function sendBonus(address _user, League _league) external onlyManager nonReentrant {
        _sendBonus(_user, _league);
    }

    /// @notice Batch version. All-or-nothing: a single entry that does not qualify — a league not
    /// above the wallet's last bonused one (a replayed backend call, a demotion re-promotion,
    /// `None`), or a league with no amount configured — reverts the whole batch. The backend must
    /// therefore filter entries with `qualifiesForBonus` before submitting.
    /// @param _users Array of user wallet addresses
    /// @param _leagues Array of destination leagues, one per user
    function sendBonusBatch(
        address[] calldata _users,
        League[] calldata _leagues
    ) external onlyManager nonReentrant {
        require(_users.length == _leagues.length, "Length mismatch");
        require(_users.length > 0, "Empty array");
        require(_users.length <= 200, "Too many users");

        for (uint256 i = 0; i < _users.length; i++) {
            _sendBonus(_users[i], _leagues[i]);
        }
    }

    /// @dev Payout precondition, also exposed to the backend via `qualifiesForBonus` so it can
    /// filter entries before submitting a batch. `None` fails it implicitly: it is the zero value,
    /// so it is never strictly higher than anything.
    function _qualifies(address _user, League _league) internal view returns (bool) {
        return _league > highestBonusedLeague[_user] && bonusAmount[_league] > 0;
    }

    function _sendBonus(address _user, League _league) internal {
        require(!killSwitch, "Kill switch is active");
        require(_user != address(0), "Invalid address");
        require(_league != League.None, "Invalid league");
        require(_qualifies(_user, _league), "Invalid league or amount");

        uint256 amount = bonusAmount[_league];
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient USDC balance");

        highestBonusedLeague[_user] = _league;
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

    /// @notice Set the bonus amount for a single league. Zero is allowed and means "promotions into
    /// this league are not paid" — a payout for such a league reverts. `None` is rejected: it is not
    /// a league, so an amount for it would be dead config.
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

    /// @notice Whether this wallet has ever been paid a league bonus
    function hasAnyBonus(address _user) external view returns (bool) {
        return highestBonusedLeague[_user] != League.None;
    }

    /// @notice Whether a (user, league) pair currently qualifies for a payout — i.e. the league is
    /// strictly higher than the highest one already paid to this wallet, and has a non-zero amount
    function qualifiesForBonus(address _user, League _league) external view returns (bool) {
        return _qualifies(_user, _league);
    }

    /// @notice Read the configured bonus amount for a given league
    function getBonusAmount(League _league) external view returns (uint256) {
        return bonusAmount[_league];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
