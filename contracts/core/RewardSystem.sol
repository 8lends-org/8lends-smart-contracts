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

    /// @notice USDC per 1e18 tokens of vesting. Zero blocks every claim — there is no token
    ///         payout left to fall back on.
    uint256 public redemptionRate;

    // Events
    event UserRegistered(address indexed user, address indexed inviter);
    event InvestmentRecorded(address indexed user, uint256 amount, uint256 projectId);
    event ProjectRewardsActivated(uint256 indexed projectId, uint256 timestamp);
    event BonusUSDCClaimed(address indexed user, uint256 amount, uint256 projectId);
    event VestingTokensClaimed(address indexed user, uint256 amount, uint256 projectId);
    event ReferralBonusRecorded(address indexed user, uint256 amount, address indexed child, uint256 projectId);
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

    modifier onlyManager() {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
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



    /// @notice Activate project rewards (called when transitioning to Stage.Funded)
    /// @param _projectId Project ID
    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested) external onlyFundraise {
        _activateProjectRewards(_projectId, _totalInvested, 0);
    }
    
    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested, uint256 _maxUSDNeeded) external onlyFundraise {
        _activateProjectRewards(_projectId, _totalInvested, _maxUSDNeeded);
    }

    function _activateProjectRewards(uint256 _projectId, uint256, uint256) internal {
        if(projectVestingStartTime[_projectId] == 0) {
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

    /// @notice Set the rate vesting is redeemed at.
    /// @param _rate USDC per 1e18 tokens — 20000 is $0.02 against six-decimal USDC. Zero is
    ///        rejected so it keeps meaning "never set" and cannot be used to stop claims.
    function setRedemptionRate(uint256 _rate) external onlyOwner {
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
    ) external onlyManager {
        require(
            _referralPercentage >= 1_000 && _referralPercentage <= 1_000_000,
            "Referral percentage must be between 1000 and 1000000"
        );
        require(_weeklyUnlock >= 1_000 && _weeklyUnlock <= 1_000_000, "Weekly unlock must be between 1000 and 1000000");
        referralPercentage = _referralPercentage;
        vestingWeeks = _vestingWeeks;
        weeklyUnlock = _weeklyUnlock;
    }

    /// @notice Calculate claimable vesting tokens for project
    /// @notice Calculate claimable vesting tokens
    /// @param _user User address
    /// @param _projectId Project ID
    function _calculateVestingAmountForProject(address _user, uint256 _projectId) internal view returns (uint256) {
        ReferralData storage refData = projectReferrals[_user][_projectId];
        uint256 vestingStartTime = projectVestingStartTime[_projectId];
        if (vestingStartTime == 0) return 0;

        uint256 weeksPassed = (block.timestamp - vestingStartTime) / 1 weeks;
        
        // First week is unlocked immediately (weeksPassed + 1)
        uint256 weeksUnlocked = weeksPassed + 1;
        
        if (weeksUnlocked >= vestingWeeks) {
            return refData.totalRewardsTokens - refData.vestingClaimedAmount;
        }

        uint256 totalUnlocked = (refData.totalRewardsTokens * weeksUnlocked * weeklyUnlock) / BASIS_POINTS;
        
        uint256 usedAdditionalUnlock = userMaxAdditionalUnlockUsed[_user][_projectId];
        if (usedAdditionalUnlock > 0) {
            totalUnlocked += (refData.totalRewardsTokens * usedAdditionalUnlock) / BASIS_POINTS;
        }

        if (totalUnlocked > refData.totalRewardsTokens) {
            totalUnlocked = refData.totalRewardsTokens;
        }

        if (totalUnlocked <= refData.vestingClaimedAmount) {
            return 0;
        }

        return totalUnlocked - refData.vestingClaimedAmount;
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
            refData.totalRewardsTokens,
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
            refData.totalRewardsTokens,
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
            totalTokens += refData.totalRewardsTokens;
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

    /// @notice Distribute vesting tokens to multiple users (owner only)
    /// @param _users Array of user addresses
    /// @param _amounts Array of token amounts to distribute
    /// @param _projectIds Array of project IDs for each user
    function distributeVestingTokens(
        address[] calldata _users,
        uint256[] calldata _amounts,
        uint256[] calldata _projectIds
    ) external onlyOwner {
        require(_users.length == _amounts.length, "Users and amounts length mismatch");
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < _users.length; i++) {
            require(_users[i] != address(0), "Invalid user address");
            require(_amounts[i] > 0, "Invalid amount");
            
            uint256 projectId = _projectIds[i];
            
            // Update ReferralData for each user
            ReferralData storage refData = projectReferrals[_users[i]][projectId];
            refData.totalRewardsTokens += _amounts[i];
            rewardTokensAmount[projectId] += _amounts[i];
        }
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

    function distributeTokens(address[] calldata _users, uint256[] calldata _amounts) external onlyOwner {
        require(_users.length == _amounts.length, "Users and amounts length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            require(_users[i] != address(0), "Invalid user address");
            require(_amounts[i] > 0, "Invalid amount");
            require(IToken(token).balanceOf(address(this)) >= _amounts[i], "Not enough tokens to distribute");

            address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_users[i]);
            IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, true);
            IERC20(address(token)).safeTransfer(claimAddress, _amounts[i]);
            IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, false);
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

        ReferralData storage refData = projectReferrals[_user][_projectId];
        require(refData.totalRewardsUSDC > 0, "No USDC rewards for this project");

        uint256 amount = refData.totalRewardsUSDC;
        refData.totalRewardsUSDC = 0;

        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_user);
        IERC20(address(usdc)).safeTransfer(claimAddress, amount);

        emit BonusUSDCClaimed(_user, amount, _projectId);
    }

    /// @notice Send vesting tokens for project to user (manager only)
    /// @param _user User address
    /// @param _projectId Project ID
    function _sendTokensForProjectToUser(address _user, uint256 _projectId) internal {
        require(_user != address(0), "Invalid user address");
        require(projectVestingStartTime[_projectId] > 0, "Project rewards not activated");

        ReferralData storage refData = projectReferrals[_user][_projectId];
        require(refData.totalRewardsTokens > 0, "No token rewards for this project");
        require(redemptionRate > 0, "Redemption rate not set");

        uint256 claimableAmount = _calculateVestingAmountForProject(_user, _projectId);
        require(claimableAmount > 0, "No tokens to claim");

        refData.vestingClaimedAmount += claimableAmount;
        rewardTokensClaimedAmount[_projectId] += claimableAmount;

        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_user);

        uint256 usdcAmount = Math.mulDiv(claimableAmount, redemptionRate, 1e18);
        require(usdcAmount > 0, "No USDC to claim");
        require(usdc.balanceOf(address(this)) >= usdcAmount, "Not enough USDC to claim");

        usdc.safeTransfer(claimAddress, usdcAmount);
        // Reports the vesting claimed, as it always did. What it was paid in is the USDC Transfer
        // next to it, and redemptionRate converts one into the other.
        emit VestingTokensClaimed(_user, claimableAmount, _projectId);
    }


    // CLAIMS
    function claimTokensForProject(uint256 _projectId) external nonReentrant {
        _sendTokensForProjectToUser(msg.sender, _projectId);
    }

    function claimUSDCForProject(uint256 _projectId) external nonReentrant {
        _sendUSDCForProjectToUser(msg.sender, _projectId);
    }


    // SENDS
    function sendTokensForProjectToUser(address _user, uint256 _projectId) external onlyManager {
        _sendTokensForProjectToUser(_user, _projectId);
    }

    function sendUSDCForProjectToUser(address _user, uint256 _projectId) external onlyManager {
        _sendUSDCForProjectToUser(_user, _projectId);
    }

    // BATCHES SENDS
    function sendTokensForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds) external onlyManager {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            _sendTokensForProjectToUser(_users[i], _projectIds[i]);
        }
    }

    function sendUSDCForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds) external onlyManager {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            _sendUSDCForProjectToUser(_users[i], _projectIds[i]);
        }
    }

    // BATCHES CLAIMS
    function claimTokensForProjectBatch(uint256[] calldata _projectIds) external nonReentrant {
        require(_projectIds.length > 0, "Empty arrays");
        require(_projectIds.length <= 500, "Too many projects");
        for (uint256 i = 0; i < _projectIds.length; i++) {
            _sendTokensForProjectToUser(msg.sender, _projectIds[i]);
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
