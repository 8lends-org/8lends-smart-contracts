// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IManagerRegistry.sol";
import "./interfaces/IFundraise.sol";

contract WelcomeBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    IManagerRegistry public managerRegistry;
    IFundraise public fundraise;

    uint256 public bonusAmount; // e.g. 30 * 1e6 for 30 USDC
    uint256 public minInvestmentAmount; // minimum investment to qualify for bonus (0 = any)
    bool public killSwitch;

    mapping(address => bool) public bonusClaimed;
    uint256 public totalPaid;
    uint256 public totalBonusCount;

    event BonusSent(address indexed user, uint256 amount, uint256 projectId);
    event KillSwitchSet(bool enabled);
    event BonusAmountSet(uint256 amount);
    event MinInvestmentAmountSet(uint256 amount);
    event ContractsUpdated(address managerRegistry, address fundraise, address usdc);

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
        address _fundraise,
        address _usdc,
        uint256 _bonusAmount
    ) public initializer {
        require(_managerRegistry != address(0), "Invalid managerRegistry");
        require(_fundraise != address(0), "Invalid fundraise");
        require(_usdc != address(0), "Invalid usdc");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        fundraise = IFundraise(_fundraise);
        usdc = IERC20(_usdc);
        bonusAmount = _bonusAmount;

        uint8 usdcDecimals = IERC20Metadata(_usdc).decimals();
        minInvestmentAmount = 100 * 10 ** usdcDecimals; // 100 USDC default
    }

    /// @notice Send welcome bonus to a user who made an investment
    /// @param _user User wallet address
    /// @param _projectId Project ID to verify investment on-chain
    function sendBonus(address _user, uint256 _projectId) external onlyManager nonReentrant {
        _sendBonus(_user, _projectId);
    }

    /// @notice Send welcome bonus to multiple users (skips already claimed)
    /// @param _users Array of user wallet addresses
    /// @param _projectIds Array of project IDs for investment verification
    function sendBonusBatch(address[] calldata _users, uint256[] calldata _projectIds) external onlyManager nonReentrant {
        require(_users.length == _projectIds.length, "Length mismatch");
        require(_users.length > 0, "Empty array");
        require(_users.length <= 200, "Too many users");

        for (uint256 i = 0; i < _users.length; i++) {
            if (bonusClaimed[_users[i]]) continue;
            _sendBonus(_users[i], _projectIds[i]);
        }
    }

    function _sendBonus(address _user, uint256 _projectId) internal {
        require(!killSwitch, "Kill switch is active");
        require(_user != address(0), "Invalid address");
        require(!bonusClaimed[_user], "Bonus already claimed");
        require(bonusAmount > 0, "Bonus amount is zero");

        // On-chain verification: user must have a qualifying investment in this project
        (uint256 investedAmount,) = fundraise.investorInfo(_user, _projectId);
        require(investedAmount > 0, "No investment found");
        require(investedAmount >= minInvestmentAmount, "Investment below minimum");

        require(usdc.balanceOf(address(this)) >= bonusAmount, "Insufficient USDC balance");

        bonusClaimed[_user] = true;
        totalPaid += bonusAmount;
        totalBonusCount++;

        usdc.safeTransfer(_user, bonusAmount);

        emit BonusSent(_user, bonusAmount, _projectId);
    }

    // --- Admin functions ---

    function setKillSwitch(bool _enabled) external onlyOwner {
        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    function setBonusAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be greater than 0");
        bonusAmount = _amount;
        emit BonusAmountSet(_amount);
    }

    function setMinInvestmentAmount(uint256 _amount) external onlyOwner {
        minInvestmentAmount = _amount;
        emit MinInvestmentAmountSet(_amount);
    }

    function updateContracts(address _managerRegistry, address _fundraise, address _usdc) external onlyOwner {
        if (_managerRegistry != address(0)) managerRegistry = IManagerRegistry(_managerRegistry);
        if (_fundraise != address(0)) fundraise = IFundraise(_fundraise);
        if (_usdc != address(0)) usdc = IERC20(_usdc);
        emit ContractsUpdated(_managerRegistry, _fundraise, _usdc);
    }

    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        IERC20(_token).safeTransfer(_recipient, _amount);
    }

    // --- View functions ---

    /// @notice Get stats for admin dashboard
    function getStats() external view returns (uint256 paid, uint256 count, uint256 balance) {
        return (totalPaid, totalBonusCount, usdc.balanceOf(address(this)));
    }

    /// @notice Check if user already received bonus
    function isClaimed(address _user) external view returns (bool) {
        return bonusClaimed[_user];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
