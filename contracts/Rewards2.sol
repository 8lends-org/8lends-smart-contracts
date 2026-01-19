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

contract Rewards2 is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // Contracts
    IManagerRegistry public managerRegistry;
    Token public token;
    IERC20 public usdc;
    IUniswapV2Router02 public uniswapRouter;

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

    // Additional unlock for sell operations (added at the end to preserve storage layout)
    uint256 public additionalUnlockPercentage; // Additional unlock percentage for sell operations (in BASIS_POINTS)
    mapping(address => mapping(uint256 => uint256)) public userMaxAdditionalUnlockUsed; // user -> vestingId -> max additional unlock used

    // Events
    event VestingCreated(address indexed user, uint256 indexed vestingId, uint256 amount, uint256 startTime);
    event VestingClaimed(address indexed user, uint256 indexed vestingId, uint256 amount);
    event VestingDeactivated(address indexed user, uint256 indexed vestingId);
    event TokensSold(address indexed sender, uint256 tokensSold, uint256 usdcReceived, address indexed recipient);
    event AdditionalUnlockSet(uint256 percentage);
    
    modifier onlyManager() {
        require(IManagerRegistry(managerRegistry).isManager(msg.sender), "Not a manager");
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

        managerRegistry = IManagerRegistry(_managerRegistry);
        token = Token(_token);
        usdc = IERC20(_usdc);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        // Initialize vesting parameters
        vestingWeeks = 40; // 40 weeks vesting
        weeklyUnlock = 25e3; // 2.5% per week (25e3/1e6*100=2.5)
    }

    /// @notice Update contracts (owner only)
    function updateContracts(address _managerRegistry, address _token, address _usdc, address _uniswapRouter)
        external
        onlyOwner
    {
        if (_managerRegistry != address(0)) managerRegistry = IManagerRegistry(_managerRegistry);
        if (_token != address(0)) token = Token(_token);
        if (_usdc != address(0)) usdc = IERC20(_usdc);
        if (_uniswapRouter != address(0)) uniswapRouter = IUniswapV2Router02(_uniswapRouter);
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


    function mintRewardsTWAP(uint256 tokensForMint) external onlyOwner {
        token.mintReward(address(this), tokensForMint);
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
            try uniswapRouter.swapTokensForExactTokens(tokensForMint, maxUSDNeeded, path, address(this), block.timestamp + 300) returns (uint256[] memory) {
                // Burn received tokens to keep totalSupply unchanged
                token.burn(tokensForMint);
            } catch {
                revert("Failed to buy back tokens: pool has no liquidity");
            }
    }


    /// @notice Create vesting for users (owner only)
    /// @param _users Array of user addresses
    /// @param _amounts Array of token amounts for vesting
    /// @dev Each call creates new vesting that starts immediately
    function createVesting(
        address[] calldata _users,
        uint256[] calldata _amounts
    ) external onlyOwner {
        require(_users.length == _amounts.length, "Users and amounts length mismatch");
        require(_users.length > 0, "Empty arrays");
        require(_users.length <= 2000, "Too many users");

        for (uint256 i = 0; i < _users.length; i++) {
            require(_users[i] != address(0), "Invalid user address");
            require(_amounts[i] > 0, "Invalid amount");
            
            address user = _users[i];
            uint256 vestingId = userVestingCount[user];
            
            vestings[user][vestingId] = Vesting({
                totalAmount: _amounts[i],
                claimedAmount: 0,
                startTime: block.timestamp,
                isActive: true
            });
            
            userVestingCount[user]++;
            totalVestings++;
            
            emit VestingCreated(user, vestingId, _amounts[i], block.timestamp);
        }
    }

    /// @notice Claim tokens from all vestings
    function claim() external nonReentrant {
        uint256 totalClaimable = 0;
        uint256 vestingCount = userVestingCount[msg.sender];
        require(vestingCount > 0, "No vestings found");

        for (uint256 i = 0; i < vestingCount; i++) {
            Vesting storage vesting = vestings[msg.sender][i];
            if (!vesting.isActive) continue;

            uint256 claimable = _calculateVestingAmount(msg.sender, i);
            if (claimable > 0) {
                vesting.claimedAmount += claimable;
                totalClaimable += claimable;
                emit VestingClaimed(msg.sender, i, claimable);
            }
        }

        require(totalClaimable > 0, "No tokens to claim");
        require(token.balanceOf(address(this)) >= totalClaimable, "Not enough tokens to claim");

        address claimAddress = managerRegistry.getInvestorClaimAddress(msg.sender);
        
        managerRegistry.setPoolStatusForReward(claimAddress, true);
        IERC20(address(token)).safeTransfer(claimAddress, totalClaimable);
        managerRegistry.setPoolStatusForReward(claimAddress, false);
    }

  

    /// @notice Send vesting tokens to multiple users (manager only)
    /// @param _users Array of user addresses
    function claimBatch(address[] calldata _users) external onlyManager nonReentrant {
        require(_users.length > 0, "Empty arrays");
        require(_users.length <= 2000, "Too many users"); // 500 users per batch

        
        for (uint256 j = 0; j < _users.length; j++) {
            address user = _users[j];
            if (user == address(0)) continue;
            
            uint256 totalClaimable = 0;
            uint256 vestingCount = userVestingCount[user];
            if (vestingCount == 0) continue;

            for (uint256 i = 0; i < vestingCount; i++) {
                Vesting storage vesting = vestings[user][i];
                if (!vesting.isActive) continue;

                uint256 claimable = _calculateVestingAmount(user, i);
                if (claimable > 0) {
                    vesting.claimedAmount += claimable;
                    totalClaimable += claimable;
                    emit VestingClaimed(user, i, claimable);
                }
            }

            if (totalClaimable == 0) continue;
            if (token.balanceOf(address(this)) < totalClaimable) continue;

            address claimAddress = managerRegistry.getInvestorClaimAddress(user);
            
            managerRegistry.setPoolStatusForReward(claimAddress, true);
            IERC20(address(token)).safeTransfer(claimAddress, totalClaimable);
            managerRegistry.setPoolStatusForReward(claimAddress, false);
        }
    }

    /// @notice Calculate claimable amount for specific vesting
    /// @param _user User address
    /// @param _vestingId Vesting ID
    /// @param _includeCurrentBonus If true, uses current additionalUnlockPercentage for sell operation
    function _calculateVestingAmount(address _user, uint256 _vestingId, bool _includeCurrentBonus) internal view returns (uint256) {
        Vesting storage vesting = vestings[_user][_vestingId];
        if (!vesting.isActive || vesting.startTime == 0) return 0;

        uint256 weeksPassed = (block.timestamp - vesting.startTime) / 1 weeks;
        
        // First week is unlocked immediately (weeksPassed + 1)
        uint256 weeksUnlocked = weeksPassed + 1;
        
        if (weeksUnlocked >= vestingWeeks) {
            return vesting.totalAmount - vesting.claimedAmount;
        }

        uint256 totalUnlocked = (vesting.totalAmount * weeksUnlocked * weeklyUnlock) / BASIS_POINTS;
        
        // Calculate effective additional unlock
        uint256 maxUsedAdditionalUnlock = userMaxAdditionalUnlockUsed[_user][_vestingId];
        uint256 effectiveAdditionalUnlock = maxUsedAdditionalUnlock;
        
        // If including current bonus (for sell operation), use max of current and saved
        if (_includeCurrentBonus && additionalUnlockPercentage > maxUsedAdditionalUnlock) {
            effectiveAdditionalUnlock = additionalUnlockPercentage;
        }
        
        if (effectiveAdditionalUnlock > 0) {
            uint256 additionalUnlock = (vesting.totalAmount * effectiveAdditionalUnlock) / BASIS_POINTS;
            totalUnlocked += additionalUnlock;
        }
        
        if (totalUnlocked > vesting.totalAmount) {
            totalUnlocked = vesting.totalAmount;
        }

        if (totalUnlocked <= vesting.claimedAmount) {
            return 0;
        }

        return totalUnlocked - vesting.claimedAmount;
    }

    /// @notice Calculate claimable amount for specific vesting (regular claim)
    function _calculateVestingAmount(address _user, uint256 _vestingId) internal view returns (uint256) {
        return _calculateVestingAmount(_user, _vestingId, false);
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

    function sellTokens(uint256 tokensForSell, address _recipient, uint256 _minUsdcAmount) external nonReentrant {
        require(_recipient != address(0), "Invalid recipient");
        require(tokensForSell > 0, "Invalid amount");
        require(token.balanceOf(msg.sender) >= tokensForSell, "Not enough tokens to sell");
        require(token.allowance(msg.sender, address(this)) >= tokensForSell, "Not enough allowance to sell");
       
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(usdc);

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensForSell);
        IERC20(address(token)).approve(address(uniswapRouter), tokensForSell);

        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(tokensForSell, _minUsdcAmount, path, _recipient, block.timestamp + 300); 
        IERC20(address(token)).approve(address(uniswapRouter), 0);
        emit TokensSold(msg.sender, tokensForSell, amounts[1], _recipient);
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
        IERC20(_token).safeTransfer(_recipient, _amount);
    }

    /// @notice Calculate claimable tokens for sell operation for a single vesting (internal helper)
    /// @param _user User address
    /// @param _vestingId Vesting ID
    /// @param _currentTotalClaimed Already claimed tokens in current batch (for balance check)
    /// @return claimableAmount Tokens available for claim and sell for this vesting
    function _calculateClaimableForSell(
        address _user, 
        uint256 _vestingId,
        uint256 _currentTotalClaimed
    ) 
        internal 
        view 
        returns (uint256 claimableAmount) 
    {
        Vesting storage vesting = vestings[_user][_vestingId];
        
        // Check if vesting is active
        if (!vesting.isActive || vesting.startTime == 0) return 0;
        
        // Calculate claimable amount WITH additional unlock
        claimableAmount = _calculateVestingAmount(_user, _vestingId, true);
        if (claimableAmount == 0) return 0;
        
        // Check if contract has enough balance
        if (token.balanceOf(address(this)) < _currentTotalClaimed + claimableAmount) return 0;
        
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


    function getUSDCForTokens(uint256 _tokenAmount) external view returns (uint256 expectedUsdcAmount, uint256 minUsdcAmount) {
        (expectedUsdcAmount, minUsdcAmount) = _calculateExpectedUsdcForTokens(_tokenAmount);
    }

    /// @notice Calculate amounts for claim and sell operation
    /// @param _user User address
    /// @return totalTokensAmount Total tokens that will be claimed and sold
    /// @return expectedUsdcAmount Expected USDC amount to receive (before slippage)
    /// @return minUsdcAmount Minimum USDC amount with 5% slippage protection
    function getClaimAndSellAmounts(address _user)
        external
        view
        returns (uint256 totalTokensAmount, uint256 expectedUsdcAmount, uint256 minUsdcAmount)
    {
        uint256 vestingCount = userVestingCount[_user];
        require(vestingCount > 0, "No vestings found");
        
        // Calculate total claimable tokens for all vestings
        totalTokensAmount = 0;
        for (uint256 i = 0; i < vestingCount; i++) {
            uint256 claimable = _calculateClaimableForSell(_user, i, totalTokensAmount);
            totalTokensAmount += claimable;
        }
        
        // Calculate expected USDC amount for token swap
        (expectedUsdcAmount, minUsdcAmount) = _calculateExpectedUsdcForTokens(totalTokensAmount);
    }

    /// @notice Claim vesting tokens and sell them for USDC (with additional unlock bonus)
    /// @param _minUsdcAmount Minimum USDC amount to receive (slippage protection)
    /// @dev Uses additionalUnlockPercentage bonus and updates userMaxAdditionalUnlockUsed
    /// @dev Claims tokens in loop, then sells total amount in one swap for better price
    function claimAndSellTokens(uint256 _minUsdcAmount) external nonReentrant {
        uint256 vestingCount = userVestingCount[msg.sender];
        require(vestingCount > 0, "No vestings found");
        
        address claimAddress = managerRegistry.getInvestorClaimAddress(msg.sender);
        uint256 totalClaimableAmount = 0;
        
        // Claim tokens for all vestings
        for (uint256 i = 0; i < vestingCount; i++) {
            // Calculate claimable amount using helper function
            uint256 claimableAmount = _calculateClaimableForSell(msg.sender, i, totalClaimableAmount);
            if (claimableAmount == 0) continue;
            
            // Update state
            Vesting storage vesting = vestings[msg.sender][i];
            vesting.claimedAmount += claimableAmount;
            
            // Update userMaxAdditionalUnlockUsed
            if (additionalUnlockPercentage > userMaxAdditionalUnlockUsed[msg.sender][i]) {
                userMaxAdditionalUnlockUsed[msg.sender][i] = additionalUnlockPercentage;
            }
            
            totalClaimableAmount += claimableAmount;
            emit VestingClaimed(msg.sender, i, claimableAmount);
        }
        
        require(totalClaimableAmount > 0, "No tokens to claim");
        
        // Sell all claimed tokens in one swap
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

    /// @notice Set additional unlock percentage for sell operations
    /// @param _percentage Additional unlock percentage (in BASIS_POINTS, e.g., 300000 = 30%)
    /// @dev This percentage is only applied when using claimAndSellTokens
    function setAdditionalUnlock(uint256 _percentage) external onlyManager {
        require(_percentage <= BASIS_POINTS, "Percentage cannot exceed 100%");
        additionalUnlockPercentage = _percentage;
        emit AdditionalUnlockSet(_percentage);
    }

    /// @notice Authorize contract upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

