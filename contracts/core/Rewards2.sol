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
    /// @dev Slot held. Nothing swaps any more: vesting is redeemed at a fixed rate.
    address private __deprecated_uniswapRouter;

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

    /// @dev Slot held. The bonus paid for selling through the pool, and that path is gone.
    uint256 private __deprecated_additionalUnlockPercentage;
    /// @notice What the bonus unlocked before it was withdrawn. Read-only now, so those curves
    ///         stay where they are.
    mapping(address => mapping(uint256 => uint256)) public userMaxAdditionalUnlockUsed;

    /// @notice USDC per 1e18 tokens of vesting. Zero blocks every claim — there is no token
    ///         payout left to fall back on.
    uint256 public redemptionRate;

    // Events
    event VestingCreated(address indexed user, uint256 indexed vestingId, uint256 amount, uint256 startTime);
    event VestingClaimed(address indexed user, uint256 indexed vestingId, uint256 amount);
    event VestingDeactivated(address indexed user, uint256 indexed vestingId);
    event RedemptionRateSet(uint256 rate);
    
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

    /// @notice Set the rate vesting is redeemed at.
    /// @param _rate USDC per 1e18 tokens — 20000 is $0.02 against six-decimal USDC. Zero is
    ///        rejected so it keeps meaning "never set" and cannot be used to stop claims.
    function setRedemptionRate(uint256 _rate) external onlyOwner {
        require(_rate > 0, "Invalid rate");
        redemptionRate = _rate;
        emit RedemptionRateSet(_rate);
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

    /// @notice Claim all vestings, paid in USDC at the redemption rate
    function claim() external nonReentrant {
        uint256 totalClaimable = 0;
        uint256 vestingCount = userVestingCount[msg.sender];
        require(vestingCount > 0, "No vestings found");
        require(redemptionRate > 0, "Redemption rate not set");

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

        uint256 usdcAmount = Math.mulDiv(totalClaimable, redemptionRate, 1e18);
        require(usdcAmount > 0, "No USDC to claim");
        require(usdc.balanceOf(address(this)) >= usdcAmount, "Not enough USDC to claim");

        usdc.safeTransfer(managerRegistry.getInvestorClaimAddress(msg.sender), usdcAmount);
    }

  

    /// @notice Pay out vesting for multiple users (manager only)
    /// @param _users Array of user addresses
    function claimBatch(address[] calldata _users) external onlyManager nonReentrant {
        require(_users.length > 0, "Empty arrays");
        require(_users.length <= 2000, "Too many users");
        require(redemptionRate > 0, "Redemption rate not set");

        for (uint256 j = 0; j < _users.length; j++) {
            address user = _users[j];
            if (user == address(0)) continue;

            uint256 vestingCount = userVestingCount[user];
            uint256 totalClaimable = 0;
            for (uint256 i = 0; i < vestingCount; i++) {
                totalClaimable += _calculateVestingAmount(user, i);
            }
            if (totalClaimable == 0) continue;

            uint256 usdcAmount = Math.mulDiv(totalClaimable, redemptionRate, 1e18);
            if (usdcAmount == 0 || usdc.balanceOf(address(this)) < usdcAmount) continue;

            // Only now the vesting is spent: a user we skip must keep it.
            for (uint256 i = 0; i < vestingCount; i++) {
                uint256 claimable = _calculateVestingAmount(user, i);
                if (claimable > 0) {
                    vestings[user][i].claimedAmount += claimable;
                    emit VestingClaimed(user, i, claimable);
                }
            }

            usdc.safeTransfer(managerRegistry.getInvestorClaimAddress(user), usdcAmount);
        }
    }

    /// @notice Calculate claimable amount for specific vesting
    /// @param _user User address
    /// @param _vestingId Vesting ID
    function _calculateVestingAmount(address _user, uint256 _vestingId) internal view returns (uint256) {
        Vesting storage vesting = vestings[_user][_vestingId];
        if (!vesting.isActive || vesting.startTime == 0) return 0;

        uint256 weeksPassed = (block.timestamp - vesting.startTime) / 1 weeks;
        
        // First week is unlocked immediately (weeksPassed + 1)
        uint256 weeksUnlocked = weeksPassed + 1;
        
        if (weeksUnlocked >= vestingWeeks) {
            return vesting.totalAmount - vesting.claimedAmount;
        }

        uint256 totalUnlocked = (vesting.totalAmount * weeksUnlocked * weeklyUnlock) / BASIS_POINTS;
        
        uint256 usedAdditionalUnlock = userMaxAdditionalUnlockUsed[_user][_vestingId];
        if (usedAdditionalUnlock > 0) {
            totalUnlocked += (vesting.totalAmount * usedAdditionalUnlock) / BASIS_POINTS;
        }

        if (totalUnlocked > vesting.totalAmount) {
            totalUnlocked = vesting.totalAmount;
        }

        if (totalUnlocked <= vesting.claimedAmount) {
            return 0;
        }

        return totalUnlocked - vesting.claimedAmount;
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

