// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/protocol/IManagerRegistry.sol";
import "../interfaces/protocol/IToken.sol";

contract RewardSystem is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // Contracts
    address public managerRegistry;
    address public token;
    IERC20 public usdc;

    /// @dev Slot held. Nothing swaps any more: vesting is redeemed at a fixed rate.
    address private __deprecated_uniswapRouter;

    /// @notice What this implementation promises its callers, not a release number. It moves only
    ///         when a change breaks them — a method removed, an argument added, a payout currency
    ///         replaced. An ordinary upgrade leaves it where it is, so a client that reads it once
    ///         can trust the answer until it changes.
    /// @dev No version() at all means a deployment older than this field, which still paid vesting
    ///      in tokens.
    uint256 public constant version = 1;

    // 1% = 10000
    uint256 public constant BASIS_POINTS = 1e6;

    // Reward system parameters (changeable)
    uint256 public referralPercentage; // USDC for the inviter, 4% since 21.09.2026
    /// @dev Held to keep the storage slot. The welcome bonus is paid by WelcomeBonus; the branch
    ///      that paid a second one from here is gone, and so is the only gate minInvestmentForBonus
    ///      ever had.
    uint256 private __deprecated_welcomeBonusAmount;
    uint256 private __deprecated_minInvestmentForBonus;

    /// @dev Slots held. Token cashback is off: nothing accrues, mints or burns against it.
    uint256 private __deprecated_tokenPercentage;
    uint256 private __deprecated_burnPercentage;

    // Vesting parameters
    uint256 public vestingWeeks; // 40 weeks vesting
    uint256 public weeklyUnlock; // 2.5% per week

    // Structures
    struct UserInfo {
        address inviter;
        /// @dev DEPRECATED, and not merely unmaintained: the welcome bonus was the only thing
        ///      that ever cleared it, so stored values mean different things depending on whether
        ///      their owner caught the bonus before it was zeroed. Nothing writes false any more,
        ///      and getUserInfo no longer returns it. Held to keep the slot.
        bool __deprecated_isNewUser;
    }

    struct ReferralData {
        uint256 totalRewardsUSDC; // For inviter
        uint256 totalRewardsTokens; // For investor (total amount in vesting)
        uint256 vestingClaimedAmount; // Already claimed amount
    }

    // Mappings
    mapping(address => UserInfo) public users; // User information
    mapping(address => mapping(uint256 => ReferralData)) public projectReferrals; // user -> projectId -> ReferralData
    mapping(address => uint256) public inviterStats; // Inviter statistics
    mapping(uint256 => uint256) public projectVestingStartTime; // Vesting start time per project
    mapping(address => address[]) public userReferrals; // inviter -> list of referred users
    mapping(uint256 => uint256) public rewardTokensAmount; // projectId -> available token amount for claim
    mapping(uint256 => uint256) public rewardTokensClaimedAmount; // projectId -> claimed token amount
    
    /// @dev Slot held. The bonus paid for an exit through the pool, which no longer exists.
    uint256 private __deprecated_additionalUnlockPercentage;
    /// @notice What the bonus unlocked before it was withdrawn, kept so those curves stay put.
    ///         Read-only now, and unreachable once the last such project ends on 2026-11-04.
    mapping(address => mapping(uint256 => uint256)) public userMaxAdditionalUnlockUsed;

    // Oracle for manipulation-resistant pricing
    /// @dev Slot held. Priced the token cashback, which is gone.
    address private __deprecated_oracle;

    /// @notice USDC per 1e18 tokens of vesting. Zero blocks the USDC half of a claim; the token
    ///         half does not need it.
    uint256 public redemptionRate;

    /// @notice When vesting stopped unlocking into tokens. What unlocked before it is still paid in
    ///         tokens, what unlocks after it in USDC. Set once, atomically with the upgrade.
    uint256 public cutover;

    /// @notice How much of a position has been paid in USDC. Held apart from `vestingClaimedAmount`
    ///         so the two halves can be claimed in either order. Counted on this side because a
    ///         position that predates `cutover` has none of it, which an empty slot already says.
    mapping(address => mapping(uint256 => uint256)) public usdcEraClaimed;

    // Events
    event UserRegistered(address indexed user, address indexed inviter);
    event InvestmentRecorded(address indexed user, uint256 amount, uint256 projectId);
    event BonusUSDCClaimed(address indexed user, uint256 amount, uint256 projectId);
    event VestingTokensClaimed(address indexed user, uint256 amount, uint256 projectId);
    /// @notice One payout, split by currency. VestingTokensClaimed counts vesting tokens; this says
    ///         what was actually sent.
    event VestingPaid(address indexed user, uint256 indexed projectId, address to, uint256 tokens, uint256 usdc);
    event ReferralBonusRecorded(address indexed user, uint256 amount, address indexed child, uint256 projectId);
    event ProjectRewardsActivated(uint256 indexed projectId, uint256 timestamp);
    event ProjectRewardsDeactivated(uint256 indexed projectId);
    event RedemptionRateSet(uint256 rate);
    event ContractsUpdated(address managerRegistry, address token, address usdc);
    event USDCAddressUpdated(address usdc);
    event TokenAddressUpdated(address token);

    event ReferralUSDCReduced(
        address indexed inviter,
        uint256 indexed projectId,
        uint256 oldAmount,
        uint256 newAmount
    );

    modifier onlyAdmin() {
        require(IManagerRegistry(managerRegistry).isAdmin(msg.sender), "Not an admin");
        _;
    }

    // Modifiers
    modifier onlyFundraise() {
        require(IManagerRegistry(managerRegistry).isFundraise(msg.sender), "Not a fundraise");
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

        managerRegistry = _managerRegistry;
        token = _token;
        usdc = IERC20(_usdc);

        // Initialize reward system parameters
        referralPercentage = 6e4; // 6% USDC for inviter (6e4/1e6*100=6)
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

    /// @notice Internal user registration with inviter
    /// @param _user User address
    /// @param _inviter Inviter address
    function _registerUser(address _user, address _inviter) internal validAddress(_user) {
        require(_inviter != _user, "Cannot invite yourself");
        require(users[_user].inviter == address(0), "User already registered");

        users[_user] = UserInfo({inviter: _inviter, __deprecated_isNewUser: true});

        inviterStats[_inviter]++;
        userReferrals[_inviter].push(_user);

        emit UserRegistered(_user, _inviter);
    }

    function recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId)
        external
        onlyFundraise
    {
        _recordInvestment(_user, _amount, _inviter, _projectId, address(usdc));
    }

    /// @notice Record investment and calculate rewards (new version with loanToken)
    /// @param _user Investor address
    /// @param _amount Investment amount
    /// @param _inviter Inviter address (if first investment)
    /// @param _projectId Project ID
    /// @param _loanToken Ignored since rewards stopped depending on the loan token's USD value.
    ///        Kept so Fundraise keeps calling the same signature.
    function recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId, address _loanToken)
        external
        onlyFundraise
    {
        _recordInvestment(_user, _amount, _inviter, _projectId, _loanToken);
    }

    function _recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId, address)
        internal
    {
        require(_amount > 0, "Invalid amount");
        // If user is not registered, register them
        if (_inviter != address(0) && users[_user].inviter == address(0)) {
            _registerUser(_user, _inviter);
        }

        UserInfo storage userInfo = users[_user];

        // Calculate rewards for inviter
        if (_inviter != address(0) && userInfo.inviter == _inviter) {
            uint256 inviterUSDC = (_amount * referralPercentage) / BASIS_POINTS;
            projectReferrals[_inviter][_projectId].totalRewardsUSDC += inviterUSDC;
            emit ReferralBonusRecorded(_inviter, inviterUSDC, _user, _projectId);
        }

        emit InvestmentRecorded(_user, _amount, _projectId);
    }


    /// @notice Record that the borrower has taken the money: the vesting clock starts, and the
    ///         inviter's bonus becomes payable.
    /// @dev Called by Fundraise when a project reaches Stage.Funded. The stamp is also what tells a
    ///      project that was running at the cutover from one funded after it.
    /// @param _projectId Project ID
    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested) external onlyFundraise {
        _activateProjectRewards(_projectId, _totalInvested, 0);
    }

    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested, uint256 _maxUSDNeeded)
        external
        onlyFundraise
    {
        _activateProjectRewards(_projectId, _totalInvested, _maxUSDNeeded);
    }

    /// @dev Both arguments priced the token reward the funding used to mint, and are ignored.
    function _activateProjectRewards(uint256 _projectId, uint256, uint256) internal {
        if (projectVestingStartTime[_projectId] == 0) {
            projectVestingStartTime[_projectId] = block.timestamp;
            emit ProjectRewardsActivated(_projectId, block.timestamp);
        }
    }

    /// @notice Get the inviter a user was registered with.
    function getUserInfo(address _user) external view returns (address inviter) {
        return users[_user].inviter;
    }

    /// @notice Get inviter statistics
    function getInviterStats(address _inviter) external view returns (uint256) {
        return inviterStats[_inviter];
    }

    /// @notice Get count of user's referrals
    /// @param _inviter Inviter address
    /// @return Number of users referred by this inviter
    function getUserReferralsCount(address _inviter) external view returns (uint256) {
        return userReferrals[_inviter].length;
    }

    /// @notice Update contracts (owner only)
    /// @dev Pass address(0) for any param to keep current value (unlike individual setters which revert on zero)
    function updateContracts(address _managerRegistry, address _token, address _usdc)
        external
        onlyOwner
    {
        if (_managerRegistry != address(0)) managerRegistry = _managerRegistry;
        if (_token != address(0)) token = _token;
        if (_usdc != address(0)) usdc = IERC20(_usdc);
        emit ContractsUpdated(_managerRegistry, _token, _usdc);
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

    /// @notice set parameters
    /// @param _referralPercentage referral percentage 60000 is 6%
    /// @param _weeklyUnlock weekly unlock 25000 is 2.5%
    /// @param _vestingWeeks vesting weeks 40 is 40 weeks
    /// @dev all percentage parameters must be less or equal to 1_000_000 (100e4 = 100%)
    function setParameters(
        uint256 _referralPercentage,
        uint256 _weeklyUnlock,
        uint256 _vestingWeeks
    ) external onlyAdmin {
        require(
            _referralPercentage >= 1_000 && _referralPercentage <= 1_000_000,
            "Referral percentage must be between 1000 and 1000000"
        );
        require(_weeklyUnlock >= 1_000 && _weeklyUnlock <= 1_000_000, "Weekly unlock must be between 1000 and 1000000");
        referralPercentage = _referralPercentage;
        vestingWeeks = _vestingWeeks;
        weeklyUnlock = _weeklyUnlock;
    }

    /// @notice Claimable vesting for a project, in vesting tokens, whatever currency pays it.
    /// @dev What the views report: one number across both halves, so a reader who wants them apart
    ///      asks getVestingClaimable.
    function _calculateVestingAmountForProject(address _user, uint256 _projectId) internal view returns (uint256) {
        (uint256 tokens, uint256 usdcTokens) = _split(_user, _projectId);
        return tokens + usdcTokens;
    }

    /// @dev Vesting credited for a project the borrower had not taken the money for by the cutover
    ///      is cancelled: those investments earn nothing. The vesting clock is stamped when the
    ///      money goes out, so a start later than the cutover says the borrower had not taken it
    ///      by then. The stored amount is left alone as history; everything that reports a number
    ///      reports zero for it.
    function _isCancelled(uint256 _projectId) internal view returns (bool) {
        uint256 vestingStartTime = projectVestingStartTime[_projectId];
        return cutover != 0 && vestingStartTime > cutover;
    }

    /// @dev Claimable now, split at the cutover: tokens for what had unlocked by then, USDC for what
    ///      unlocked since. The cutover is capped at now, so before it everything counts as tokens.
    function _split(address _user, uint256 _projectId) internal view returns (uint256 tokens, uint256 usdcTokens) {
        if (_isCancelled(_projectId)) return (0, 0);
        ReferralData storage refData = projectReferrals[_user][_projectId];

        uint256 usdcPaid = usdcEraClaimed[_user][_projectId];
        // Whatever of the total watermark is not the USDC half was paid in tokens.
        uint256 tokensPaid = refData.vestingClaimedAmount - usdcPaid;

        uint256 unlockedByCutover = _unlockedAt(_user, _projectId, Math.min(cutover, block.timestamp));
        if (unlockedByCutover > tokensPaid) tokens = unlockedByCutover - tokensPaid;

        uint256 afterCutover = _unlockedAt(_user, _projectId, block.timestamp) - unlockedByCutover;
        if (afterCutover > usdcPaid) usdcTokens = afterCutover - usdcPaid;
    }

    /// @dev Total unlocked by `_at`: the weekly curve plus the bonus ratchet some positions carry.
    ///      Reads the current vestingWeeks and weeklyUnlock, so changing them moves the cutover
    ///      split of past unlocks as well.
    function _unlockedAt(address _user, uint256 _projectId, uint256 _at) internal view returns (uint256) {
        ReferralData storage refData = projectReferrals[_user][_projectId];
        uint256 vestingStartTime = projectVestingStartTime[_projectId];
        if (vestingStartTime == 0 || _at < vestingStartTime) return 0;

        // First week is unlocked immediately (weeksPassed + 1)
        uint256 weeksUnlocked = (_at - vestingStartTime) / 1 weeks + 1;
        if (weeksUnlocked >= vestingWeeks) return refData.totalRewardsTokens;

        uint256 totalUnlocked = (refData.totalRewardsTokens * weeksUnlocked * weeklyUnlock) / BASIS_POINTS;

        uint256 usedAdditionalUnlock = userMaxAdditionalUnlockUsed[_user][_projectId];
        if (usedAdditionalUnlock > 0) {
            totalUnlocked += (refData.totalRewardsTokens * usedAdditionalUnlock) / BASIS_POINTS;
        }

        return Math.min(totalUnlocked, refData.totalRewardsTokens);
    }

    /// @notice Get vesting information for project
    function getVestingInfoForProject(address _user, uint256 _projectId)
        external
        view
        returns (uint256 totalAmount, uint256 claimedAmount, uint256 claimableAmount, uint256 startTime, bool isActive)
    {
        ReferralData storage refData = projectReferrals[_user][_projectId];
        uint256 vestingStartTime = projectVestingStartTime[_projectId];
        return (
            _isCancelled(_projectId) ? 0 : refData.totalRewardsTokens,
            refData.vestingClaimedAmount,
            _calculateVestingAmountForProject(_user, _projectId),
            vestingStartTime,
            vestingStartTime > 0
        );
    }

    /// @notice Get project rewards information
    function getProjectRewards(address _user, uint256 _projectId)
        external
        view
        returns (
            uint256 totalUSDC,
            uint256 totalTokens,
            uint256 claimedTokens,
            uint256 claimableTokens,
            bool isActivated
        )
    {
        ReferralData storage refData = projectReferrals[_user][_projectId];
        uint256 vestingStartTime = projectVestingStartTime[_projectId];
        return (
            refData.totalRewardsUSDC,
            _isCancelled(_projectId) ? 0 : refData.totalRewardsTokens,
            refData.vestingClaimedAmount,
            _calculateVestingAmountForProject(_user, _projectId),
            vestingStartTime > 0
        );
    }

    /// @notice Get total rewards across multiple projects for a user
    /// @param _user User address
    /// @param _projectIds Array of project IDs to check
    /// @return totalUSDC Total USDC rewards across all projects
    /// @return totalTokens Total token rewards across all projects
    /// @return claimedTokens Total claimed tokens across all projects
    /// @return claimableTokens Total claimable tokens across all projects
    function getProjectsRewardsTotal(address _user, uint256[] calldata _projectIds) 
        external 
        view 
        returns (uint256 totalUSDC, uint256 totalTokens, uint256 claimedTokens, uint256 claimableTokens) 
    {
        require(_projectIds.length > 0, "Empty project IDs array");
        require(_projectIds.length <= 500, "Too many projects");
        
        totalUSDC = 0;
        totalTokens = 0;
        claimedTokens = 0;
        claimableTokens = 0;
        
        for (uint256 i = 0; i < _projectIds.length; i++) {
            uint256 projectId = _projectIds[i];
            ReferralData storage refData = projectReferrals[_user][projectId];
            
            totalUSDC += refData.totalRewardsUSDC;
            if (!_isCancelled(projectId)) totalTokens += refData.totalRewardsTokens;
            claimedTokens += refData.vestingClaimedAmount;
            claimableTokens += _calculateVestingAmountForProject(_user, projectId);
        }
    }

    /// @notice Authorize contract upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function updateUSDCAddress(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Zero address");
        usdc = IERC20(_usdc);
        emit USDCAddressUpdated(_usdc);
    }

    function updateTokenAddress(address _token) external onlyOwner {
        require(_token != address(0), "Zero address");
        token = _token;
        emit TokenAddressUpdated(_token);
    }

    function deactivateProject(uint256 _projectId) external onlyOwner {
        projectVestingStartTime[_projectId] = 0;
        emit ProjectRewardsDeactivated(_projectId);
    }

    /// @notice Subtract mistakenly credited USDC referral bonuses (owner only)
    /// @param _inviters               Inviter addresses (bucket key)
    /// @param _projectIds             Project IDs (parallel with _inviters)
    /// @param _reductions             Amounts of USDC to subtract from each bucket (delta)
    /// @param _expectedCurrentAmount  On-chain totalRewardsUSDC value at the moment of
    ///                                off-chain snapshot preparation. Used when the current on-chain state differs
    function reduceReferralUSDC(
        address[] calldata _inviters,
        uint256[] calldata _projectIds,
        uint256[] calldata _reductions,
        uint256[] calldata _expectedCurrentAmount
    ) external onlyOwner {
        uint256 len = _inviters.length;
        require(len == _projectIds.length, "Users and projectIds length mismatch");
        require(len == _reductions.length, "Users and reductions length mismatch");
        require(len == _expectedCurrentAmount.length, "Users and expected length mismatch");
        require(len <= 500, "Batch too large");

        for (uint256 i = 0; i < len; i++) {
            // Bigger-than-snapshot delta signals stale off-chain data
            require(_reductions[i] <= _expectedCurrentAmount[i], "Reduction exceeds expected current amount");

            ReferralData storage refData = projectReferrals[_inviters[i]][_projectIds[i]];
            uint256 currentAmount = refData.totalRewardsUSDC;
            uint256 reduction = _reductions[i];

            // Bucket shrunk (claim happened or previous batch reduced it) — skip.
            if (currentAmount < _expectedCurrentAmount[i]) continue;

            if (reduction == 0) continue;

            uint256 newAmount = currentAmount - reduction;
            refData.totalRewardsUSDC = newAmount;

            emit ReferralUSDCReduced(_inviters[i], _projectIds[i], currentAmount, newAmount);
        }
    }

    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner nonReentrant {
        require(_token != address(0), "Invalid token");
        require(_recipient != address(0), "Invalid recipient");

        // The token only transfers to a pool. Flag the recipient for it, unless it already is one
        // — clearing the flag afterwards would then break it.
        IManagerRegistry registry = IManagerRegistry(managerRegistry);
        bool gate = _token == token && !registry.isPool(_recipient);
        if (gate) registry.setPoolStatusForReward(_recipient, true);
        IERC20(_token).safeTransfer(_recipient, _amount);
        if (gate) registry.setPoolStatusForReward(_recipient, false);
    }


   

    /// @notice Send USDC rewards for project to user (manager only)
    /// @param _user User address
    /// @param _projectId Project ID
    function _sendUSDCForProjectToUser(address _user, uint256 _projectId) internal {
        require(_user != address(0), "Invalid user address");
        require(projectVestingStartTime[_projectId] > 0, "Project rewards not activated");

        address claimAddress = _payoutTarget(_user);

        ReferralData storage refData = projectReferrals[_user][_projectId];
        require(refData.totalRewardsUSDC > 0, "No USDC rewards for this project");

        uint256 amount = refData.totalRewardsUSDC;
        refData.totalRewardsUSDC = 0;

        IERC20(address(usdc)).safeTransfer(claimAddress, amount);

        emit BonusUSDCClaimed(_user, amount, _projectId);
    }

    /// @dev Shared head of both halves.
    function _requireVesting(address _user, uint256 _projectId) private view {
        require(_user != address(0), "Invalid user address");
        require(projectVestingStartTime[_projectId] > 0, "Project rewards not activated");
        require(cutover != 0, "Cutover not set");
        require(!_isCancelled(_projectId), "Vesting cancelled for this project");
        require(projectReferrals[_user][_projectId].totalRewardsTokens > 0, "No token rewards for this project");
    }

    /// @dev Marks a half paid and reports it against the position. `_usdcHalf` also moves the
    ///      watermark that tells the two apart.
    function _settle(address _user, uint256 _projectId, uint256 _amount, bool _usdcHalf) private {
        projectReferrals[_user][_projectId].vestingClaimedAmount += _amount;
        rewardTokensClaimedAmount[_projectId] += _amount;
        if (_usdcHalf) usdcEraClaimed[_user][_projectId] += _amount;
        emit VestingTokensClaimed(_user, _amount, _projectId);
    }

    /// @notice Pay what unlocked before the cutover, in tokens.
    function _sendVestingTokens(address _user, uint256 _projectId) internal {
        _requireVesting(_user, _projectId);
        address claimAddress = _payoutTarget(_user);

        (uint256 tokens,) = _split(_user, _projectId);
        require(tokens > 0, "No tokens to claim");
        require(IERC20(token).balanceOf(address(this)) >= tokens, "Not enough tokens to claim");

        _settle(_user, _projectId, tokens, false);

        _sendTokens(claimAddress, tokens);
        emit VestingPaid(_user, _projectId, claimAddress, tokens, 0);
    }

    /// @notice Pay what unlocked after the cutover, in USDC at the redemption rate.
    /// @dev Independent of the token half: either may be taken first, or on its own. A slice too
    ///      small to buy a whole micro-dollar is left owed rather than written off, so it joins the
    ///      next one.
    function _sendVestingUsdc(address _user, uint256 _projectId) internal {
        _requireVesting(_user, _projectId);
        address claimAddress = _payoutTarget(_user);
        // There is no token fallback here, so an unset rate stops the claim rather than consume the
        // position and pay nothing for it.
        require(redemptionRate > 0, "Redemption rate not set");

        (, uint256 usdcTokens) = _split(_user, _projectId);
        require(usdcTokens > 0, "No tokens to claim");

        uint256 usdcAmount = getUSDCForTokens(usdcTokens);
        require(usdcAmount > 0, "No USDC to claim");
        require(usdc.balanceOf(address(this)) >= usdcAmount, "Not enough USDC to claim");

        // Spends only what the payout covers: converting the rounded amount back says how much
        // vesting it actually bought.
        _settle(_user, _projectId, Math.mulDiv(usdcAmount, 1e18, redemptionRate), true);

        usdc.safeTransfer(claimAddress, usdcAmount);
        emit VestingPaid(_user, _projectId, claimAddress, 0, usdcAmount);
    }

    /// @dev Read on the address the money reaches, never on the caller: the caller may be an
    ///      admin pressing the support button on someone else's behalf.
    function _payoutTarget(address _user) internal view returns (address) {
        address claimAddress = IManagerRegistry(managerRegistry).recipientOf(_user);
        require(!IManagerRegistry(managerRegistry).isFrozen(claimAddress), "Account frozen");
        return claimAddress;
    }

    /// @dev 8LNDS moves only to a pool while buying is disabled, so the recipient is flagged for the
    ///      transfer. A real pool keeps its flag.
    function _sendTokens(address _to, uint256 _amount) private {
        IManagerRegistry registry = IManagerRegistry(managerRegistry);
        bool gate = !registry.isPool(_to);
        if (gate) registry.setPoolStatusForReward(_to, true);
        IERC20(token).safeTransfer(_to, _amount);
        if (gate) registry.setPoolStatusForReward(_to, false);
    }

    /// @notice What a claim right now would pay out for one project.
    /// @return inTokens Vesting tokens, handed over as tokens: what unlocked before the cutover
    /// @return usdcAmount USDC for what unlocked after it, at the current rate, 6 decimals
    function getVestingClaimable(address _user, uint256 _projectId)
        external
        view
        returns (uint256 inTokens, uint256 usdcAmount)
    {
        uint256 usdcTokens;
        (inTokens, usdcTokens) = _split(_user, _projectId);
        usdcAmount = getUSDCForTokens(usdcTokens);
    }


    // CLAIMS
    function claimVestingTokensForProject(uint256 _projectId) external nonReentrant {
        _sendVestingTokens(msg.sender, _projectId);
    }

    function claimVestingUsdcForProject(uint256 _projectId) external nonReentrant {
        _sendVestingUsdc(msg.sender, _projectId);
    }

    function claimUSDCForProject(uint256 _projectId) external nonReentrant {
        _sendUSDCForProjectToUser(msg.sender, _projectId);
    }


    // SENDS
    function sendVestingTokensForProjectToUser(address _user, uint256 _projectId) external onlyAdmin {
        _sendVestingTokens(_user, _projectId);
    }

    function sendVestingUsdcForProjectToUser(address _user, uint256 _projectId) external onlyAdmin {
        _sendVestingUsdc(_user, _projectId);
    }

    function sendUSDCForProjectToUser(address _user, uint256 _projectId) external onlyAdmin {
        _sendUSDCForProjectToUser(_user, _projectId);
    }

    // BATCHES SENDS
    function sendVestingTokensForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds)
        external
        onlyAdmin
    {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            _sendVestingTokens(_users[i], _projectIds[i]);
        }
    }

    function sendVestingUsdcForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds)
        external
        onlyAdmin
    {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            _sendVestingUsdc(_users[i], _projectIds[i]);
        }
    }

    function sendUSDCForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds) external onlyAdmin {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            _sendUSDCForProjectToUser(_users[i], _projectIds[i]);
        }
    }

    // BATCHES CLAIMS
    function claimVestingTokensForProjectBatch(uint256[] calldata _projectIds) external nonReentrant {
        require(_projectIds.length > 0, "Empty arrays");
        require(_projectIds.length <= 500, "Too many projects");
        for (uint256 i = 0; i < _projectIds.length; i++) {
            _sendVestingTokens(msg.sender, _projectIds[i]);
        }
    }

    function claimVestingUsdcForProjectBatch(uint256[] calldata _projectIds) external nonReentrant {
        require(_projectIds.length > 0, "Empty arrays");
        require(_projectIds.length <= 500, "Too many projects");
        for (uint256 i = 0; i < _projectIds.length; i++) {
            _sendVestingUsdc(msg.sender, _projectIds[i]);
        }
    }

    function claimUSDCForProjectBatch(uint256[] calldata _projectIds) external nonReentrant {
        require(_projectIds.length > 0, "Empty arrays");
        require(_projectIds.length <= 500, "Too many projects");
        
        for (uint256 i = 0; i < _projectIds.length; i++) {
            _sendUSDCForProjectToUser(msg.sender, _projectIds[i]);
        }
    }
}
