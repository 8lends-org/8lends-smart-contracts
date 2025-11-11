// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IManagerRegistry.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./Token.sol";

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
    uint256 public burnPercentage; // 6% tokens for burning

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

    // Events
    event UserRegistered(address indexed user, address indexed inviter);
    event InvestmentRecorded(address indexed user, uint256 amount, uint256 projectId);
    event ProjectRewardsActivated(uint256 indexed projectId, uint256 timestamp);
    event BonusUSDCClaimed(address indexed user, uint256 amount, uint256 projectId);
    event VestingTokensClaimed(address indexed user, uint256 amount, uint256 projectId);
    event WelcomeBonusRecorded(address indexed user, uint256 amount);
    event ReferralBonusRecorded(address indexed user, uint256 amount, address indexed child, uint256 projectId);

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
        welcomeBonusAmount = 30e6; // 30 USDC for investor (6 decimals)
        minInvestmentForBonus = 1000e6; // Minimum 1000 USDC for bonus
        tokenPercentage = 6e4; // 6% tokens for investor (6e4/1e6*100=6)
        burnPercentage = 6e4; // 6% tokens for burning (6e4/1e6*100=6)
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

    /// @notice Record investment and calculate rewards
    /// @param _user Investor address
    /// @param _amount Investment amount in USDC
    /// @param _inviter Inviter address (if first investment)
    /// @param _projectId Project ID
    function recordInvestment(address _user, uint256 _amount, address _inviter, uint256 _projectId)
        external
        onlyFundraise
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

        if (usdcRewardAmount <= 0) revert("Invalid USDC reward amount");

        if (token == address(0)) revert("Token address is not set");
        if (address(usdc) == address(0)) revert("USDC address is not set");
        if (address(uniswapRouter) == address(0)) revert("Uniswap router address is not set");

        // Get current Token price in USDC
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = token;
        
        uint256[] memory amounts;
        try uniswapRouter.getAmountsOut(usdcRewardAmount, path) returns (uint256[] memory _amounts) {
            amounts = _amounts;
        } catch {
            revert("Uniswap pool does not exist or has no liquidity");
        }
        
        uint256 tokensAmount = amounts[1];
        require(tokensAmount > 0, "Invalid token amount from Uniswap");

        refData.totalRewardsTokens += tokensAmount;
        rewardTokensAmount[_projectId] += tokensAmount;

        // Bonus for investor (if investment >= minimum and this is new user)
        if (userInfo.isNewUser && _amount >= minInvestmentForBonus) {
            refData.totalRewardsUSDC += welcomeBonusAmount;
            userInfo.isNewUser = false;
            emit WelcomeBonusRecorded(_user, welcomeBonusAmount);
        }

        emit InvestmentRecorded(_user, _amount, _projectId);
    }



    /// @notice Activate project rewards (called when transitioning to Stage.Funded)
    /// @param _projectId Project ID
    function activateProjectRewards(uint256 _projectId, uint256 _totalInvested) external onlyFundraise {
        require(projectVestingStartTime[_projectId] == 0, "Rewards already activated");
        projectVestingStartTime[_projectId] = block.timestamp;
        emit ProjectRewardsActivated(_projectId, block.timestamp);

        if (_totalInvested > 0) {
            uint256 tokensForMint = rewardTokensAmount[_projectId];
            
            // Mint rewarded tokens to RewardSystem contract
            if (tokensForMint > 0) {
                Token(token).mintReward(address(this), tokensForMint);

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
                    
                    // Add 1% slippage tolerance
                    uint256 maxUSDNeeded = (exactUSDNeeded * 101) / 100;
                    if (maxUSDNeeded > usdc.balanceOf(address(this))) {
                        revert("Not enough USDC to buy tokens");
                    }
                    
                    usdc.approve(address(uniswapRouter), maxUSDNeeded);
                    
                    // Buy exact amount of tokens from pool (USDC -> Token)
                    try uniswapRouter.swapTokensForExactTokens(tokensForMint, maxUSDNeeded, path, address(this), block.timestamp) returns (uint256[] memory) {
                        // Burn received tokens to keep totalSupply unchanged
                        Token(token).burn(tokensForMint);
                    } catch {
                        revert("Failed to buy back tokens: pool has no liquidity");
                    }
                }
            }
        }
    }

    /// @notice Claim USDC rewards for project
    /// @param _projectId Project ID
    function claimUSDCForProject(uint256 _projectId) external nonReentrant {
        require(projectVestingStartTime[_projectId] > 0, "Project rewards not activated");

        ReferralData storage refData = projectReferrals[msg.sender][_projectId];
        require(refData.totalRewardsUSDC > 0, "No USDC rewards for this project");

        uint256 claimableAmount = refData.totalRewardsUSDC;
        refData.totalRewardsUSDC = 0;

        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(msg.sender);
        IERC20(address(usdc)).safeTransfer(claimAddress, claimableAmount);

        emit BonusUSDCClaimed(msg.sender, claimableAmount, _projectId);
    }

    /// @notice Claim vesting tokens for project
    /// @param _projectId Project ID
    function claimTokensForProject(uint256 _projectId) external nonReentrant {
        require(projectVestingStartTime[_projectId] > 0, "Project rewards not activated");

        ReferralData storage refData = projectReferrals[msg.sender][_projectId];
        require(refData.totalRewardsTokens > 0, "No token rewards for this project");

        uint256 claimableAmount = _calculateVestingAmountForProject(msg.sender, _projectId);
        require(claimableAmount > 0, "No tokens to claim");
        require(Token(token).balanceOf(address(this)) >= claimableAmount, "Not enough tokens to claim");

        refData.vestingClaimedAmount += claimableAmount;

        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(msg.sender);
        
        IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, true);
        IERC20(address(token)).safeTransfer(claimAddress, claimableAmount);
        IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, false);

        rewardTokensClaimedAmount[_projectId] += claimableAmount;
        emit VestingTokensClaimed(msg.sender, claimableAmount, _projectId);
    }

    /// @notice Send USDC rewards for project to user (manager only)
    /// @param _user User address
    /// @param _projectId Project ID
    function sendUSDCForProjectToUser(address _user, uint256 _projectId) external onlyManager {
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
    function sendTokensForProjectToUser(address _user, uint256 _projectId) external onlyManager {
        require(_user != address(0), "Invalid user address");
        require(projectVestingStartTime[_projectId] > 0, "Project rewards not activated");

        ReferralData storage refData = projectReferrals[_user][_projectId];
        require(refData.totalRewardsTokens > 0, "No token rewards for this project");

        uint256 claimableAmount = _calculateVestingAmountForProject(_user, _projectId);
        require(claimableAmount > 0, "No tokens to claim");
        require(Token(token).balanceOf(address(this)) >= claimableAmount, "Not enough tokens to claim");

        refData.vestingClaimedAmount += claimableAmount;

        address claimAddress = IManagerRegistry(managerRegistry).getInvestorClaimAddress(_user);
        IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, true);
        IERC20(address(token)).safeTransfer(claimAddress, claimableAmount);
        IManagerRegistry(managerRegistry).setPoolStatusForReward(claimAddress, false);

        rewardTokensClaimedAmount[_projectId] += claimableAmount;
        emit VestingTokensClaimed(_user, claimableAmount, _projectId);
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
    function updateContracts(address _managerRegistry, address _token, address _usdc)
        external
        onlyOwner
    {
        if (_managerRegistry != address(0)) managerRegistry = _managerRegistry;
        if (_token != address(0)) token = _token;
        if (_usdc != address(0)) usdc = IERC20(_usdc);
    }

    /// @notice set parameters
    /// @param _referralPercentage referral percentage 60000 is 6%
    /// @param _burnPercentage burn percentage 60000 is 6%
    /// @param _tokenPercentage token percentage 60 is 6%
    /// @param _welcomeBonusAmount welcome bonus amount 30_000_000 is 30 USDC
    /// @param _minInvestmentForBonus min investment for bonus 1000000000 is 1000 USDC
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
        if (totalUnlocked > refData.totalRewardsTokens) {
            totalUnlocked = refData.totalRewardsTokens;
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

    /// @notice Authorize contract upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function updateUSDCAddress(address _usdc) external onlyOwner {
        usdc = IERC20(_usdc);
    }

    function updateTokenAddress(address _token) external onlyOwner {
        token = _token;
    }

    function updateUniswapRouterAddress(address _uniswapRouter) external onlyOwner {
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
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

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _users.length; i++) {
            require(_users[i] != address(0), "Invalid user address");
            require(_amounts[i] > 0, "Invalid amount");
            
            uint256 projectId = _projectIds[i];
            
            // Activate project vesting if not activated yet
            if(projectVestingStartTime[projectId] == 0) {
                projectVestingStartTime[projectId] = block.timestamp;
                emit ProjectRewardsActivated(projectId, block.timestamp);
            }
            
            totalAmount += _amounts[i];
            
            // Update ReferralData for each user
            ReferralData storage refData = projectReferrals[_users[i]][projectId];
            refData.totalRewardsTokens += _amounts[i];
            rewardTokensAmount[projectId] += _amounts[i];
        }
    }

    function withdraw(address _token, uint256 _amount, address _recepient) external onlyOwner {
        IERC20(_token).safeTransfer(_recepient, _amount);
    }

    function sendTokensForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds) external onlyManager {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            this.sendTokensForProjectToUser(_users[i], _projectIds[i]);
        }
    }

    function sendUSDCForProjectToUserBatch(address[] calldata _users, uint256[] calldata _projectIds) external onlyManager {
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        require(_users.length > 0, "Empty arrays");
        for (uint256 i = 0; i < _users.length; i++) {
            this.sendUSDCForProjectToUser(_users[i], _projectIds[i]);
        }
    }
}
