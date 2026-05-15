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
import "./interfaces/IManagerRegistry.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IToken.sol";
import "../oracle/interfaces/IOracle.sol";

contract RewardSystem is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // Contracts
    address public managerRegistry;
    address public token;
    IERC20 public usdc;

    // Uniswap contracts
    IUniswapV2Router02 public uniswapRouter;

    // 1% = 10000
    uint256 public constant BASIS_POINTS = 1e6;

    // Reward system parameters (changeable)
    uint256 public referralPercentage; // 6% USDC for inviter
    uint256 public welcomeBonusAmount; // 30 USDC for investor (6 decimals)
    uint256 public minInvestmentForBonus; // Minimum 1000 USDC for bonus
    uint256 public tokenPercentage; // 6% tokens for investor
    /// @notice When > 0, enables buy-back-and-burn during reward activation. Value represents the burn percentage in BASIS_POINTS.
    uint256 public burnPercentage;

    // Vesting parameters
    uint256 public vestingWeeks; // 40 weeks vesting
    uint256 public weeklyUnlock; // 2.5% per week

    // Structures
    struct UserInfo {
        address inviter;
        bool isNewUser;
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
    
    // Additional unlock for sell operations (added at the end to preserve storage layout)
    uint256 public additionalUnlockPercentage; // Additional unlock percentage for sell operations (in BASIS_POINTS)
    mapping(address => mapping(uint256 => uint256)) public userMaxAdditionalUnlockUsed; // user -> projectId -> max additional unlock used

    // Oracle for manipulation-resistant pricing
    address public oracle;

    // Events
    event OracleUpdated(address oracle);
    event UserRegistered(address indexed user, address indexed inviter);
    event InvestmentRecorded(address indexed user, uint256 amount, uint256 projectId);
    event ProjectRewardsActivated(uint256 indexed projectId, uint256 timestamp);
    event BonusUSDCClaimed(address indexed user, uint256 amount, uint256 projectId);
    event VestingTokensClaimed(address indexed user, uint256 amount, uint256 projectId);
    event WelcomeBonusRecorded(address indexed user, uint256 amount);
    event ReferralBonusRecorded(address indexed user, uint256 amount, address indexed child, uint256 projectId);
    event ProjectRewardsDeactivated(uint256 indexed projectId);
    event AdditionalUnlockSet(uint256 percentage);
    event TokensSold(address indexed sender, uint256 tokensSold, uint256 usdcReceived, address indexed recipient);
    event ContractsUpdated(address managerRegistry, address token, address usdc);
    event USDCAddressUpdated(address usdc);
    event TokenAddressUpdated(address token);
    event UniswapRouterUpdated(address router);

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
        address _uniswapRouter
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = _managerRegistry;
        token = _token;
        usdc = IERC20(_usdc);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);

        // Initialize reward system parameters
        referralPercentage = 6e4; // 6% USDC for inviter (6e4/1e6*100=6)
        uint8 usdcDecimals = IERC20Metadata(_usdc).decimals();
        welcomeBonusAmount = 30 * 10**usdcDecimals; // 30 USDC for investor
        minInvestmentForBonus = 1000 * 10**usdcDecimals; // Minimum 1000 USDC for bonus
        tokenPercentage = 6e4; // 6% tokens for investor (6e4/1e6*100=6)
        burnPercentage = 6e4; // 6% tokens for burning (6e4/1e6*100=6). When > 0, enables buy-back-and-burn.
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

        users[_user] = UserInfo({inviter: _inviter, isNewUser: true});

        inviterStats[_inviter]++;
        userReferrals[_inviter].push(_user);

        emit UserRegistered(_user, _inviter);
    }

    /// @notice Backward-compatible overload for old Fundraise contract (before upgrade).
    /// @dev TODO: remove after Fundraise upgrade deploys. Assumes loanToken = USDC.
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
    /// @param _loanToken Loan token address for price conversion
    function recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId, address _loanToken)
        external
        onlyFundraise
    {
        _recordInvestment(_user, _amount, _inviter, _projectId, _loanToken);
    }

    function _recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId, address _loanToken)
        internal
    {
        require(_amount > 0, "Invalid amount");
        // If user is not registered, register them
        if (_inviter != address(0) && users[_user].inviter == address(0)) {
            _registerUser(_user, _inviter);
        }

        UserInfo storage userInfo = users[_user];

        // Initialize ReferralData for project if it doesn't exist
        ReferralData storage refData = projectReferrals[_user][_projectId];

        // Calculate rewards for inviter
        address inviter = userInfo.inviter;
        if (inviter != address(0)) {
            uint256 inviterUSDC = (_amount * referralPercentage) / BASIS_POINTS;
            projectReferrals[inviter][_projectId].totalRewardsUSDC += inviterUSDC;
            emit ReferralBonusRecorded(inviter, inviterUSDC, _user, _projectId);
        }

        // Calculate rewards for investor (tokens)
        uint256 usdcRewardAmount = (_amount * tokenPercentage) / BASIS_POINTS;

        if (usdcRewardAmount == 0) revert("Invalid USDC reward amount");

        if (token == address(0)) revert("Token address is not set");
        if (address(usdc) == address(0)) revert("USDC address is not set");

        uint256 tokensAmount;
        if (oracle != address(0)) {
            // New path: manipulation-resistant price from Oracle (Pyth + TWAP)
            IOracle.PriceResult memory priceResult = IOracle(oracle).getPrice(token);
            require(priceResult.price > 0, "Oracle: no valid price");
            uint8 tokenDecimals = IERC20Metadata(token).decimals();
            uint8 usdcDecimals = IERC20Metadata(address(usdc)).decimals();
            uint8 priceDecimals = IOracle(oracle).priceDecimals();
            // Convert usdcRewardAmount to token amount using oracle price
            // tokensAmount = usdcRewardAmount * 10^priceDecimals * 10^tokenDecimals / (price * 10^usdcDecimals)
            tokensAmount = Math.mulDiv(
                Math.mulDiv(usdcRewardAmount, 10**priceDecimals, priceResult.price),
                10**tokenDecimals,
                10**usdcDecimals
            );
        } else {
            // Legacy fallback: Uniswap V2 spot price (used before Oracle is deployed)
            require(address(uniswapRouter) != address(0), "Uniswap router address is not set");
            address[] memory path = new address[](2);
            path[0] = address(usdc);
            path[1] = token;
            uint256[] memory amounts;
            try uniswapRouter.getAmountsOut(usdcRewardAmount, path) returns (uint256[] memory _amounts) {
                amounts = _amounts;
            } catch {
                revert("Uniswap pool does not exist or has no liquidity");
            }
            tokensAmount = amounts[1];
        }
        require(tokensAmount > 0, "Invalid token amount");

        refData.totalRewardsTokens += tokensAmount;
        rewardTokensAmount[_projectId] += tokensAmount;

        // Bonus for investor (if investment USD value >= minimum and this is new user)
        if(welcomeBonusAmount > 0) {
            if (userInfo.isNewUser && _convertToUSD(_amount, _loanToken) >= minInvestmentForBonus) {
                refData.totalRewardsUSDC += welcomeBonusAmount;
                userInfo.isNewUser = false;
                emit WelcomeBonusRecorded(_user, welcomeBonusAmount);
            }
        }

        emit InvestmentRecorded(_user, _amount, _projectId);
    }



    /// @notice Convert a token amount to its USD equivalent (in USDC decimals)
    /// @dev Uses Oracle when available; falls back to 1:1 for USDC or reverts for non-USDC without oracle
    /// @param _amount Raw amount in token units
    /// @param _loanToken Token address to get the price for
    /// @return USD value normalized to USDC decimals
    function _convertToUSD(uint256 _amount, address _loanToken) internal view returns (uint256) {
        if (oracle != address(0)) {
            // Oracle path: full price conversion
            IOracle.PriceResult memory loanPriceResult = IOracle(oracle).getPrice(_loanToken);
            uint8 loanTokenDecimals = IERC20Metadata(_loanToken).decimals();
            uint8 _usdcDecimals = IERC20Metadata(address(usdc)).decimals();
            uint8 _priceDecimals = IOracle(oracle).priceDecimals();
            if (loanTokenDecimals >= _usdcDecimals) {
                return Math.mulDiv(_amount, loanPriceResult.price, 10**_priceDecimals * 10**(loanTokenDecimals - _usdcDecimals));
            } else {
                return Math.mulDiv(_amount * 10**(_usdcDecimals - loanTokenDecimals), loanPriceResult.price, 10**_priceDecimals);
            }
        } else {
            // Legacy fallback: if loanToken is USDC, amount is already in USD
            if (_loanToken == address(usdc)) {
                return _amount;
            }
            // Non-USDC tokens require oracle for price conversion
            revert("Oracle required for non-USDC loan tokens");
        }
    }

    /// @notice Activate project rewards (called when transitioning to Stage.Funded)
    /// @param _projectId Project ID
    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested) external onlyFundraise {
        _activateProjectRewards(_projectId, _totalInvested, 0);
    }
    
    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested, uint256 _maxUSDNeeded) external onlyFundraise {
        _activateProjectRewards(_projectId, _totalInvested, _maxUSDNeeded);
    }

    function _activateProjectRewards(uint256 _projectId, uint256 _totalInvested, uint256 _maxUSDNeeded) internal {
        if(projectVestingStartTime[_projectId] == 0) {
            projectVestingStartTime[_projectId] = block.timestamp;
            emit ProjectRewardsActivated(_projectId, block.timestamp);
            if (_totalInvested > 0) {
                _mintRewardsForProject(_projectId, _maxUSDNeeded);
            }
        }
    }

   

    /// @notice Get user information
    function getUserInfo(address _user) external view returns (address inviter, bool isNewUser) {
        UserInfo storage userInfo = users[_user];
        return (userInfo.inviter, userInfo.isNewUser);
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

    /// @notice Set oracle address for manipulation-resistant pricing
    /// @param _oracle Oracle contract address
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid address");
        oracle = _oracle;
        emit OracleUpdated(_oracle);
    }

    /// @notice set parameters
    /// @param _referralPercentage referral percentage 60000 is 6%
    /// @param _burnPercentage burn percentage 60000 is 6%
    /// @param _tokenPercentage token percentage 60000 is 6%
    /// @param _welcomeBonusAmount welcome bonus amount in USDC-decimal units (dynamic, not hardcoded to 6 decimals)
    /// @param _minInvestmentForBonus min investment for bonus in USDC-decimal units (dynamic, not hardcoded to 6 decimals)
    /// @param _weeklyUnlock weekly unlock 2_500_000 is 2.5%
    /// @param _vestingWeeks vesting weeks 40 is 40 weeks
    /// @dev all percentage parameters must be less or equal to 1_000_000 (100e4 = 100%)
    function setParameters(
        uint256 _referralPercentage,
        uint256 _burnPercentage,
        uint256 _tokenPercentage,
        uint256 _welcomeBonusAmount,
        uint256 _minInvestmentForBonus,
        uint256 _weeklyUnlock,
        uint256 _vestingWeeks
    ) external onlyManager {
        require(
            _referralPercentage >= 1_000 && _referralPercentage <= 1_000_000,
            "Referral percentage must be between 1000 and 1000000"
        );
        require(
            _tokenPercentage >= 1_000 && _tokenPercentage <= 1_000_000,
            "Token percentage must be between 1000 and 1000000"
        );
        require(_weeklyUnlock >= 1_000 && _weeklyUnlock <= 1_000_000, "Weekly unlock must be between 1000 and 1000000");
        require(
            _burnPercentage >= 1_000 && _burnPercentage <= 1_000_000, "Burn percentage must be between 1000 and 1000000"
        );
        referralPercentage = _referralPercentage;
        welcomeBonusAmount = _welcomeBonusAmount;
        minInvestmentForBonus = _minInvestmentForBonus;
        tokenPercentage = _tokenPercentage;
        vestingWeeks = _vestingWeeks;
        weeklyUnlock = _weeklyUnlock;
        burnPercentage = _burnPercentage;
    }

    /// @notice Calculate claimable vesting tokens for project
    /// @notice Calculate claimable vesting tokens
    /// @param _user User address
    /// @param _projectId Project ID
    /// @param _includeCurrentBonus If true, uses current additionalUnlockPercentage for sell operation
    function _calculateVestingAmountForProject(address _user, uint256 _projectId, bool _includeCurrentBonus) internal view returns (uint256) {
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
        
        // Calculate effective additional unlock
        uint256 maxUsedAdditionalUnlock = userMaxAdditionalUnlockUsed[_user][_projectId];
        uint256 effectiveAdditionalUnlock = maxUsedAdditionalUnlock;
        
        // If including current bonus (for sell operation), use max of current and saved
        if (_includeCurrentBonus && additionalUnlockPercentage > maxUsedAdditionalUnlock) {
            effectiveAdditionalUnlock = additionalUnlockPercentage;
        }
        
        if (effectiveAdditionalUnlock > 0) {
            uint256 additionalUnlock = (refData.totalRewardsTokens * effectiveAdditionalUnlock) / BASIS_POINTS;
            totalUnlocked += additionalUnlock;
        }
        
        if (totalUnlocked > refData.totalRewardsTokens) {
            totalUnlocked = refData.totalRewardsTokens;
        }

        if (totalUnlocked <= refData.vestingClaimedAmount) {
            return 0;
        }

        return totalUnlocked - refData.vestingClaimedAmount;
    }

    /// @notice Calculate claimable vesting tokens (regular claim)
    function _calculateVestingAmountForProject(address _user, uint256 _projectId) internal view returns (uint256) {
        return _calculateVestingAmountForProject(_user, _projectId, false);
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

    function updateUniswapRouterAddress(address _uniswapRouter) external onlyOwner {
        require(_uniswapRouter != address(0), "Zero address");
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        emit UniswapRouterUpdated(_uniswapRouter);
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

    /// @notice Set additional unlock percentage for sell operations
    /// @param _percentage Additional unlock percentage (in BASIS_POINTS, e.g., 300000 = 30%)
    /// @dev This percentage is only applied when using claimAndSellTokensForProjectBatch
    function setAdditionalUnlock(uint256 _percentage) external onlyManager {
        require(_percentage <= BASIS_POINTS, "Percentage cannot exceed 100%");
        additionalUnlockPercentage = _percentage;
        emit AdditionalUnlockSet(_percentage);
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
        IERC20(_token).safeTransfer(_recipient, _amount);
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

        uint256 claimableAmount = _calculateVestingAmountForProject(_user, _projectId);
        require(claimableAmount > 0, "No tokens to claim");
        require(IToken(token).balanceOf(address(this)) >= claimableAmount, "Not enough tokens to claim");

        refData.vestingClaimedAmount += claimableAmount;

        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_user);
        IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, true);
        IERC20(address(token)).safeTransfer(claimAddress, claimableAmount);
        IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, false);

        rewardTokensClaimedAmount[_projectId] += claimableAmount;
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

    /// @notice Calculate claimable tokens for sell operation for a single project (internal helper)
    /// @param _user User address
    /// @param _projectId Project ID
    /// @param _currentTotalClaimed Already claimed tokens in current batch (for balance check)
    /// @return claimableAmount Tokens available for claim and sell for this project
    function _calculateClaimableForSellForProject(
        address _user, 
        uint256 _projectId,
        uint256 _currentTotalClaimed
    ) 
        internal 
        view 
        returns (uint256 claimableAmount) 
    {
        // Check if vesting has started
        if (projectVestingStartTime[_projectId] == 0) return 0;
        
        // Check if user has rewards for this project
        ReferralData storage refData = projectReferrals[_user][_projectId];
        if (refData.totalRewardsTokens == 0) return 0;
        
        // Calculate claimable amount WITH additional unlock
        claimableAmount = _calculateVestingAmountForProject(_user, _projectId, true);
        if (claimableAmount == 0) return 0;
        
        // Check if contract has enough balance
        if (IToken(token).balanceOf(address(this)) < _currentTotalClaimed + claimableAmount) return 0;
        
        return claimableAmount;
    }

    /// @notice Calculate expected USDC amount for token swap (internal helper)
    /// @param _tokenAmount Amount of tokens to swap
    /// @return expectedUsdcAmount Expected USDC amount to receive (before slippage)
    /// @return minUsdcAmount Minimum USDC amount with 5% slippage protection
    function _calculateExpectedUsdcForTokens(uint256 _tokenAmount)
        internal
        view
        returns (uint256 expectedUsdcAmount, uint256 minUsdcAmount)
    {

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(usdc);

        if (_tokenAmount == 0) {
            return (0, 0);
        }

        try uniswapRouter.getAmountsOut(_tokenAmount, path) returns (uint256[] memory amounts) {
            expectedUsdcAmount = amounts[1];
            minUsdcAmount = (expectedUsdcAmount * 95) / 100; // 5% slippage tolerance
        } catch {
            // If pool doesn't exist or has no liquidity, return 0
            expectedUsdcAmount = 0;
            minUsdcAmount = 0;
        }
    }

    /// @notice Calculate amounts for claim and sell batch operation
    /// @param _user User address
    /// @param _projectIds Array of project IDs
    /// @return totalTokensAmount Total tokens that will be claimed and sold
    /// @return expectedUsdcAmount Expected USDC amount to receive (before slippage)
    /// @return minUsdcAmount Minimum USDC amount with 5% slippage protection
    function getClaimAndSellAmounts(address _user, uint256[] calldata _projectIds)
        external
        view
        returns (uint256 totalTokensAmount, uint256 expectedUsdcAmount, uint256 minUsdcAmount)
    {
        require(_projectIds.length > 0, "Empty array");
        require(_projectIds.length <= 500, "Too many projects");
        
        // Calculate total claimable tokens for all projects
        totalTokensAmount = 0;
        for (uint256 i = 0; i < _projectIds.length; i++) {
            uint256 claimable = _calculateClaimableForSellForProject(_user, _projectIds[i], totalTokensAmount);
            totalTokensAmount += claimable;
        }
        
        // Calculate expected USDC amount for token swap (ignore path)
        (expectedUsdcAmount, minUsdcAmount ) = _calculateExpectedUsdcForTokens(totalTokensAmount);
    }

    /// @notice Claim vesting tokens and sell them for USDC (with additional unlock bonus)
    /// @param _projectIds Array of project IDs
    /// @param _minUsdcAmount Minimum USDC amount to receive (slippage protection)
    /// @dev Uses additionalUnlockPercentage bonus and updates userMaxAdditionalUnlockUsed
    /// @dev Claims tokens in loop, then sells total amount in one swap for better price
    function claimAndSellTokensForProjectBatch(uint256[] calldata _projectIds, uint256 _minUsdcAmount) external nonReentrant {
        require(_projectIds.length > 0, "Empty array");
        require(_projectIds.length <= 500, "Too many projects");
        
        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(msg.sender);
        uint256 totalClaimableAmount = 0;
        
        // Claim tokens for all projects
        for (uint256 i = 0; i < _projectIds.length; i++) {
            uint256 projectId = _projectIds[i];
            
            // Calculate claimable amount using helper function
            uint256 claimableAmount = _calculateClaimableForSellForProject(msg.sender, projectId, totalClaimableAmount);
            if (claimableAmount == 0) continue;
            
            // Update state
            ReferralData storage refData = projectReferrals[msg.sender][projectId];
            refData.vestingClaimedAmount += claimableAmount;
            rewardTokensClaimedAmount[projectId] += claimableAmount;
            
            // Update userMaxAdditionalUnlockUsed
            if (additionalUnlockPercentage > userMaxAdditionalUnlockUsed[msg.sender][projectId]) {
                userMaxAdditionalUnlockUsed[msg.sender][projectId] = additionalUnlockPercentage;
            }
            
            totalClaimableAmount += claimableAmount;
            emit VestingTokensClaimed(msg.sender, claimableAmount, projectId);
        }
        
        // Sell all claimed tokens in one swap
        if (totalClaimableAmount > 0) {
            // Calculate expected USDC amount with slippage protection and get swap path
            address[] memory path = new address[](2);
            path[0] = address(token);
            path[1] = address(usdc);
            
            // Approve tokens for Uniswap router
            IERC20(address(token)).approve(address(uniswapRouter), totalClaimableAmount);
            
            // Swap tokens for USDC with slippage protection
            uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
                totalClaimableAmount,
                _minUsdcAmount, // Minimum USDC to receive (5% slippage protection)
                path,
                claimAddress,
                block.timestamp
            );
            
            // Reset approval for security
            IERC20(address(token)).approve(address(uniswapRouter), 0);
            
            emit TokensSold(msg.sender, totalClaimableAmount, amounts[1], claimAddress);
        }
    }

    function mintRewardsTWAP(uint256 _amount, uint256 _maxUSDNeeded) external onlyOwner {
        _mintRewards(_amount, _maxUSDNeeded);
    }

    function _mintRewards(uint256 tokensForMint, uint256 maxUSDNeeded) internal {
        IToken(token).mintReward(address(this), tokensForMint);
        
        // Buy back tokens from pool (USDC -> Token) and burn them
        // Burn exactly the same amount as minted to keep totalSupply unchanged
        if (burnPercentage > 0) {
            address[] memory path = new address[](2);
            path[0] = address(usdc);
            path[1] = address(token);
            
            // Calculate how much USDC is needed to buy tokensForMint tokens
            uint256 exactUSDNeeded;
            try uniswapRouter.getAmountsIn(tokensForMint, path) returns (uint256[] memory _amounts) {
                exactUSDNeeded = _amounts[0];
            } catch {
                revert("Failed to calculate USDC needed for tokens");
            }

            // Check if maxUSDNeeded is set, if not, set it to 1% more than exactUSDNeeded
            if(maxUSDNeeded == 0)  maxUSDNeeded = (exactUSDNeeded * 101) / 100;
            
            // Check if exactUSDNeeded is greater than maxUSDNeeded, if so, revert
            if (exactUSDNeeded > maxUSDNeeded) revert("Exceeds max USDC needed");
            
            // Check if maxUSDNeeded is greater than the balance of USDC in the contract, if so, revert
            if (maxUSDNeeded > usdc.balanceOf(address(this))) revert("Not enough USDC to buy tokens");
            
            
            usdc.approve(address(uniswapRouter), maxUSDNeeded);
            
            // Buy exact amount of tokens from pool (USDC -> Token)
            try uniswapRouter.swapTokensForExactTokens(tokensForMint, maxUSDNeeded, path, address(this), block.timestamp) returns (uint256[] memory) {
                // Burn received tokens to keep totalSupply unchanged
                IToken(token).burn(tokensForMint);
            } catch {
                revert("Failed to buy back tokens: pool has no liquidity");
            }
        }
    }

    function _mintRewardsForProject(uint256 _projectId, uint256 _maxUSDNeeded) internal {
        uint256 tokensForMint = rewardTokensAmount[_projectId];
        if (tokensForMint > 0) {
            _mintRewards(tokensForMint, _maxUSDNeeded);
        }
    }

    function mintRewardsForProject(uint256 _projectId, uint256 _maxUSDNeeded) external onlyOwner {
        _mintRewardsForProject(_projectId, _maxUSDNeeded);
    }
}