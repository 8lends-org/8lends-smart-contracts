// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/protocol/IManagerRegistry.sol";
import "../interfaces/protocol/IToken.sol";

contract Rewards2 is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // Contracts
    IManagerRegistry public managerRegistry;
    IToken public token;
    IERC20 public usdc;
    /// @dev Slot held, nothing reads it.
    address private __deprecated_uniswapRouter;

    /// @notice What this implementation promises its callers, not a release number. It moves only
    ///         when a change breaks them — a method removed, an argument added, a payout currency
    ///         replaced. An ordinary upgrade leaves it where it is, so a client that reads it once
    ///         can trust the answer until it changes.
    /// @dev No version() at all means a deployment older than this field.
    uint256 public constant version = 1;

    // 1% = 10000
    uint256 public constant BASIS_POINTS = 1e6;

    // Vesting parameters
    uint256 public vestingWeeks; // 40 weeks vesting
    uint256 public weeklyUnlock; // 2.5% per week

    // Structure
    struct Vesting {
        uint256 totalAmount; // Total amount in this vesting
        uint256 claimedAmount; // Already claimed amount
        uint256 startTime; // Vesting start time
        bool isActive; // Vesting is active
    }

    // Mappings
    mapping(address => mapping(uint256 => Vesting)) public vestings; // user -> vestingId -> Vesting
    mapping(address => uint256) public userVestingCount; // user -> number of vestings
    uint256 public totalVestings; // Total number of vestings created

    /// @dev Slot held, nothing reads it.
    uint256 private __deprecated_additionalUnlockPercentage;
    /// @notice Extra share of a vesting unlocked on top of the weekly curve, in basis points.
    ///         Read-only: nothing writes it, and the curves that carry it keep it.
    mapping(address => mapping(uint256 => uint256)) public userMaxAdditionalUnlockUsed;

    /// @notice USDC per 1e18 tokens of vesting. Zero blocks every claim — there is no token
    ///         payout left to fall back on.
    uint256 public redemptionRate;

    /// @notice When vesting stopped unlocking into tokens. What unlocked before it is still paid in
    ///         tokens, what unlocks after it in USDC. Set once, atomically with the upgrade.
    uint256 public cutover;

    /// @notice How much of a vesting has been paid in USDC. Held apart from `claimedAmount` so the
    ///         two halves can be claimed in either order. Counted on this side because a vesting
    ///         that predates `cutover` has none of it, which an empty slot already says.
    mapping(address => mapping(uint256 => uint256)) public usdcEraClaimed;

    // Events
    event VestingClaimed(address indexed user, uint256 indexed vestingId, uint256 amount);
    event VestingDeactivated(address indexed user, uint256 indexed vestingId);
    event RedemptionRateSet(uint256 rate);
    /// @notice One payout, split by currency. VestingClaimed counts vesting tokens per vesting; this
    ///         says what was actually sent, which a reader cannot reconstruct without the cutover.
    event ClaimPaid(address indexed user, address indexed to, uint256 tokens, uint256 usdc);
    
    modifier onlyAdmin() {
        require(IManagerRegistry(managerRegistry).isAdmin(msg.sender), "Not an admin");
        _;
    }

    modifier validAddress(address _addr) {
        require(_addr != address(0), "Invalid address");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _managerRegistry,
        address _token,
        address _usdc,
        address
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        token = IToken(_token);
        usdc = IERC20(_usdc);
        // Initialize vesting parameters
        vestingWeeks = 40; // 40 weeks vesting
        weeklyUnlock = 25e3; // 2.5% per week (25e3/1e6*100=2.5)
        // A fresh deployment has no token era: nothing has unlocked before now.
        cutover = block.timestamp;
    }

    /// @notice Fixes the cutover. Called by the Safe inside upgradeToAndCall, so no claim can land
    ///         between the code switching to USDC and the moment being recorded.
    function initializeCutover() external reinitializer(2) onlyOwner {
        cutover = block.timestamp;
    }

    /// @notice Update contracts (owner only)
    function updateContracts(address _managerRegistry, address _token, address _usdc) external onlyOwner {
        if (_managerRegistry != address(0)) managerRegistry = IManagerRegistry(_managerRegistry);
        if (_token != address(0)) token = IToken(_token);
        if (_usdc != address(0)) usdc = IERC20(_usdc);
    }

    /// @notice Set vesting parameters (owner only)
    /// @param _weeklyUnlock weekly unlock 2_500_000 is 2.5%
    /// @param _vestingWeeks vesting weeks 40 is 40 weeks
    function setVestingParameters(
        uint256 _weeklyUnlock,
        uint256 _vestingWeeks
    ) external onlyOwner {
        require(_weeklyUnlock >= 1_000 && _weeklyUnlock <= 1_000_000, "Weekly unlock must be between 1000 and 1000000");
        require(_vestingWeeks > 0, "Vesting weeks must be greater than 0");
        weeklyUnlock = _weeklyUnlock;
        vestingWeeks = _vestingWeeks;
    }

    /// @notice What a vesting amount is worth at the current redemption rate.
    /// @param _tokenAmount Vesting tokens, 18 decimals
    /// @return USDC, 6 decimals. Zero while the rate is unset, which is also when claims revert.
    function getUSDCForTokens(uint256 _tokenAmount) public view returns (uint256) {
        return Math.mulDiv(_tokenAmount, redemptionRate, 1e18);
    }

    /// @notice Set the rate vesting is redeemed at.
    /// @param _rate USDC per 1e18 tokens — 20000 is $0.02 against six-decimal USDC. Zero is
    ///        rejected so it keeps meaning "never set" and cannot be used to stop claims.
    function setRedemptionRate(uint256 _rate) external onlyAdmin {
        require(_rate > 0, "Invalid rate");
        redemptionRate = _rate;
        emit RedemptionRateSet(_rate);
    }

    /// @notice Claim what unlocked before the cutover. Paid in tokens.
    function claimTokens() external nonReentrant {
        require(userVestingCount[msg.sender] > 0, "No vestings found");
        require(cutover != 0, "Cutover not set");

        (address to, bool allowed) = _payoutTarget(msg.sender);
        require(allowed, "Account frozen");

        uint256 tokens = _tokensOwed(msg.sender);
        require(tokens > 0, "No tokens to claim");
        require(token.balanceOf(address(this)) >= tokens, "Not enough tokens to claim");

        _settleTokens(msg.sender);
        _sendTokens(to, tokens);
        emit ClaimPaid(msg.sender, to, tokens, 0);
    }

    /// @notice Claim what unlocked after the cutover. Paid in USDC at the redemption rate.
    /// @dev Independent of claimTokens: either half may be taken first, or on its own.
    function claimUsdc() external nonReentrant {
        require(userVestingCount[msg.sender] > 0, "No vestings found");
        require(cutover != 0, "Cutover not set");

        // There is no token fallback here, so an unset rate stops the claim rather than consume the
        // vesting and pay nothing for it.
        require(redemptionRate > 0, "Redemption rate not set");

        (address to, bool allowed) = _payoutTarget(msg.sender);
        require(allowed, "Account frozen");

        uint256 usdcAmount = _settleUsdc(msg.sender);
        require(usdcAmount > 0, "No USDC to claim");
        require(usdc.balanceOf(address(this)) >= usdcAmount, "Not enough USDC to claim");
        usdc.safeTransfer(to, usdcAmount);
        emit ClaimPaid(msg.sender, to, 0, usdcAmount);
    }

    /// @notice Pay the token era for many users
    /// @dev A user the contract cannot pay in full is skipped and keeps the vesting.
    /// @param _users Array of user addresses
    function claimTokensBatch(address[] calldata _users) external onlyAdmin nonReentrant {
        _requireBatch(_users.length);

        for (uint256 j = 0; j < _users.length; j++) {
            address user = _users[j];
            if (user == address(0)) continue;

            (address to, bool allowed) = _payoutTarget(user);
            if (!allowed) continue;

            uint256 tokens = _tokensOwed(user);
            if (tokens == 0 || token.balanceOf(address(this)) < tokens) continue;

            _settleTokens(user);
            _sendTokens(to, tokens);
            emit ClaimPaid(user, to, tokens, 0);
        }
    }

    /// @notice Pay the USDC half for many users
    /// @dev A user the contract cannot pay in full is skipped and keeps the vesting.
    /// @param _users Array of user addresses
    function claimUsdcBatch(address[] calldata _users) external onlyAdmin nonReentrant {
        _requireBatch(_users.length);
        require(redemptionRate > 0, "Redemption rate not set");

        for (uint256 j = 0; j < _users.length; j++) {
            address user = _users[j];
            if (user == address(0)) continue;

            (address to, bool allowed) = _payoutTarget(user);
            if (!allowed) continue;

            uint256 usdcAmount = _usdcOwed(user);
            if (usdcAmount == 0 || usdc.balanceOf(address(this)) < usdcAmount) continue;

            _settleUsdc(user);
            usdc.safeTransfer(to, usdcAmount);
            emit ClaimPaid(user, to, 0, usdcAmount);
        }
    }

    /// @dev Read on the address the money reaches, never on the caller. Returned rather than
    ///      enforced, because a single claim refuses and a batch skips.
    function _payoutTarget(address _user) private view returns (address to, bool allowed) {
        to = managerRegistry.recipientOf(_user);
        allowed = !managerRegistry.isFrozen(to);
    }

    function _requireBatch(uint256 _length) private view {
        require(_length > 0, "Empty arrays");
        require(_length <= 2000, "Too many users");
        require(cutover != 0, "Cutover not set");
    }

    /// @notice What a claim right now would pay out.
    /// @return inTokens Vesting tokens, handed over as tokens: what unlocked before the cutover
    /// @return usdcAmount USDC for what unlocked after it, at the current rate, 6 decimals
    function getClaimable(address _user) external view returns (uint256 inTokens, uint256 usdcAmount) {
        inTokens = _tokensOwed(_user);
        usdcAmount = _usdcOwed(_user);
    }

    /// @dev What the token era still owes across every vesting of the user.
    function _tokensOwed(address _user) internal view returns (uint256 tokens) {
        uint256 count = userVestingCount[_user];
        for (uint256 i = 0; i < count; i++) {
            (uint256 t,) = _split(_user, i);
            tokens += t;
        }
    }

    /// @dev Marks the token era paid, leaving the USDC half owed. Only the total watermark moves:
    ///      the other one counts USDC and this half is not it.
    function _settleTokens(address _user) internal {
        uint256 count = userVestingCount[_user];
        for (uint256 i = 0; i < count; i++) {
            (uint256 tokens,) = _split(_user, i);
            if (tokens > 0) {
                vestings[_user][i].claimedAmount += tokens;
                emit VestingClaimed(_user, i, tokens);
            }
        }
    }

    /// @dev Marks the USDC half paid, leaving the token era owed. Both watermarks move: the total
    ///      one counts vesting tokens whatever currency paid them, the other only this half.
    /// @dev Spends only what the payout covers: the amount is rounded down to whole micro-dollars,
    ///      and converting it back says how much vesting that actually bought. The remainder is
    ///      worth less than a micro-dollar and stays owed, so it joins next week's slice instead of
    ///      being written off.
    function _settleUsdc(address _user) internal returns (uint256 usdcAmount) {
        uint256 count = userVestingCount[_user];
        for (uint256 i = 0; i < count; i++) {
            (, uint256 usdcTokens) = _split(_user, i);
            if (usdcTokens == 0) continue;

            uint256 amount = getUSDCForTokens(usdcTokens);
            if (amount == 0) continue;

            uint256 paidTokens = Math.mulDiv(amount, 1e18, redemptionRate);
            vestings[_user][i].claimedAmount += paidTokens;
            usdcEraClaimed[_user][i] += paidTokens;
            usdcAmount += amount;
            emit VestingClaimed(_user, i, paidTokens);
        }
    }

    /// @dev What the USDC half comes to, rounded per vesting exactly as the payout rounds it.
    function _usdcOwed(address _user) internal view returns (uint256 usdcAmount) {
        uint256 count = userVestingCount[_user];
        for (uint256 i = 0; i < count; i++) {
            (, uint256 usdcTokens) = _split(_user, i);
            if (usdcTokens > 0) usdcAmount += getUSDCForTokens(usdcTokens);
        }
    }

    /// @dev 8LNDS moves only to a pool while buying is disabled, so the recipient is flagged for the
    ///      transfer. A real pool keeps its flag.
    function _sendTokens(address _to, uint256 _amount) internal {
        bool gate = !managerRegistry.isPool(_to);
        if (gate) managerRegistry.setPoolStatusForReward(_to, true);
        IERC20(address(token)).safeTransfer(_to, _amount);
        if (gate) managerRegistry.setPoolStatusForReward(_to, false);
    }

    /// @notice Claimable amount for a vesting, in vesting tokens, whatever currency pays it.
    /// @dev What the views below report: one number across both halves, so a reader who wants them
    ///      apart asks getClaimable.
    function _calculateVestingAmount(address _user, uint256 _vestingId) internal view returns (uint256) {
        (uint256 tokens, uint256 usdcTokens) = _split(_user, _vestingId);
        return tokens + usdcTokens;
    }

    /// @dev Claimable now, split at the cutover: tokens for what had unlocked by then, USDC for what
    ///      unlocked since. The cutover is capped at now, so before it everything counts as tokens.
    function _split(address _user, uint256 _vestingId) internal view returns (uint256 tokens, uint256 usdcTokens) {
        Vesting storage vesting = vestings[_user][_vestingId];
        if (!vesting.isActive) return (0, 0);

        uint256 usdcPaid = usdcEraClaimed[_user][_vestingId];
        // Whatever of the total watermark is not the USDC half was paid in tokens.
        uint256 tokensPaid = vesting.claimedAmount - usdcPaid;

        uint256 unlockedByCutover = _unlockedAt(_user, _vestingId, Math.min(cutover, block.timestamp));
        if (unlockedByCutover > tokensPaid) tokens = unlockedByCutover - tokensPaid;

        uint256 afterCutover = _unlockedAt(_user, _vestingId, block.timestamp) - unlockedByCutover;
        if (afterCutover > usdcPaid) usdcTokens = afterCutover - usdcPaid;
    }

    /// @dev Total unlocked by `_at`: the weekly curve plus the bonus ratchet some vestings still carry.
    ///      Reads the current vestingWeeks and weeklyUnlock, so changing them moves the cutover split
    ///      of past unlocks as well.
    function _unlockedAt(address _user, uint256 _vestingId, uint256 _at) internal view returns (uint256) {
        Vesting storage vesting = vestings[_user][_vestingId];
        if (vesting.startTime == 0 || _at < vesting.startTime) return 0;

        // First week is unlocked immediately (weeksPassed + 1)
        uint256 weeksUnlocked = (_at - vesting.startTime) / 1 weeks + 1;
        if (weeksUnlocked >= vestingWeeks) return vesting.totalAmount;

        uint256 unlocked = (vesting.totalAmount * weeksUnlocked * weeklyUnlock) / BASIS_POINTS;
        uint256 usedAdditionalUnlock = userMaxAdditionalUnlockUsed[_user][_vestingId];
        if (usedAdditionalUnlock > 0) {
            unlocked += (vesting.totalAmount * usedAdditionalUnlock) / BASIS_POINTS;
        }
        return Math.min(unlocked, vesting.totalAmount);
    }

    /// @notice Get all vestings info for user
    /// @param _user User address
    /// @return vestingIds Array of vesting IDs
    /// @return totalAmounts Array of total amounts
    /// @return claimedAmounts Array of claimed amounts
    /// @return claimableAmounts Array of claimable amounts
    /// @return startTimes Array of start times
    /// @return activeStatuses Array of active statuses
    function getVestingsInfo(address _user)
        external
        view
        returns (
            uint256[] memory vestingIds,
            uint256[] memory totalAmounts,
            uint256[] memory claimedAmounts,
            uint256[] memory claimableAmounts,
            uint256[] memory startTimes,
            bool[] memory activeStatuses
        )
    {
        uint256 count = userVestingCount[_user];
        vestingIds = new uint256[](count);
        totalAmounts = new uint256[](count);
        claimedAmounts = new uint256[](count);
        claimableAmounts = new uint256[](count);
        startTimes = new uint256[](count);
        activeStatuses = new bool[](count);

        for (uint256 i = 0; i < count; i++) {
            Vesting storage vesting = vestings[_user][i];
            vestingIds[i] = i;
            totalAmounts[i] = vesting.totalAmount;
            claimedAmounts[i] = vesting.claimedAmount;
            claimableAmounts[i] = _calculateVestingAmount(_user, i);
            startTimes[i] = vesting.startTime;
            activeStatuses[i] = vesting.isActive;
        }
    }

    /// @notice Get total claimable amount across all vestings
    /// @param _user User address
    function getBalances(address _user) external view returns (uint256 tokensAll, uint256 tokensClaimable, uint256 tokensClaimed, uint256 tokensBalance, uint256 USDCBalance) {
        tokensBalance = token.balanceOf(_user);
        USDCBalance = usdc.balanceOf(_user);
        uint256 count = userVestingCount[_user];

        for (uint256 i = 0; i < count; i++) {
            if (vestings[_user][i].isActive) {
                tokensClaimable += _calculateVestingAmount(_user, i);
                tokensClaimed += vestings[_user][i].claimedAmount;
                tokensAll += vestings[_user][i].totalAmount;
            }
        }
    }

    /// @notice Get specific vesting info
    /// @param _user User address
    /// @param _vestingId Vesting ID
    function getVestingInfo(address _user, uint256 _vestingId)
        external
        view
        returns (uint256 totalAmount, uint256 claimedAmount, uint256 claimableAmount, uint256 startTime, bool isActive)
    {
        require(_vestingId < userVestingCount[_user], "Invalid vesting ID");
        Vesting storage vesting = vestings[_user][_vestingId];
        return (
            vesting.totalAmount,
            vesting.claimedAmount,
            _calculateVestingAmount(_user, _vestingId),
            vesting.startTime,
            vesting.isActive
        );
    }

    /// @notice Deactivate specific vesting (owner only)
    /// @param _user User address
    /// @param _vestingId Vesting ID
    function deactivateVesting(address _user, uint256 _vestingId) external onlyOwner {
        require(_vestingId < userVestingCount[_user], "Invalid vesting ID");
        vestings[_user][_vestingId].isActive = false;
        emit VestingDeactivated(_user, _vestingId);
    }

    /// @notice Withdraw tokens (owner only)
    /// @param _token Token address
    /// @param _amount Amount to withdraw
    /// @param _recipient Recipient address
    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner {
        bool gate = _token == address(token) && !managerRegistry.isPool(_recipient);
        if (gate) managerRegistry.setPoolStatusForReward(_recipient, true);
        IERC20(_token).safeTransfer(_recipient, _amount);
        if (gate) managerRegistry.setPoolStatusForReward(_recipient, false);
    }

    /// @notice Authorize contract upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

