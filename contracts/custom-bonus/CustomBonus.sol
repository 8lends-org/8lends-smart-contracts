// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IManagerRegistry.sol";

/// @title CustomBonus
/// @notice USDC bonus of arbitrary amount paid to a user, triggered by the backend.
/// Idempotency: `paymentId = keccak256(user, bonusType, campaignId)` — a repeated call
/// with the same triple is rejected.
contract CustomBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    IManagerRegistry public managerRegistry;

    bool public killSwitch;

    uint256 public totalPaid;
    uint256 public totalBonusCount;
    mapping(bytes32 => bool) public bonusPaid;

    mapping(uint8 => mapping(uint256 => uint256)) public campaignPaid;
    mapping(uint8 => mapping(uint256 => uint256)) public campaignBonusCount;

    event CustomBonusPaid(
        bytes32 indexed paymentId,
        address indexed user,
        uint8 indexed bonusType,
        uint256 campaignId,
        uint256 amount
    );
    event KillSwitchSet(bool enabled);
    event ContractsUpdated(address managerRegistry, address usdc);

    modifier onlyManager() {
        require(managerRegistry.isManager(msg.sender), "Not a manager");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _managerRegistry, address _usdc) public initializer {
        require(_managerRegistry != address(0), "Invalid managerRegistry");
        require(_usdc != address(0), "Invalid usdc");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        usdc = IERC20(_usdc);
    }

    /// @notice Send bonus to a user. Reverts if the (user, bonusType, campaignId) triple was already paid.
    /// @param _bonusType Backend-defined enum encoded as uint8 (e.g. 1 = Marketing, 2 = Support, ...).
    function sendCustomBonus(
        address _user,
        uint8 _bonusType,
        uint256 _campaignId,
        uint256 _amount
    ) external onlyManager nonReentrant {
        _sendCustomBonus(_user, _bonusType, _campaignId, _amount);
    }

    /// @notice Batch version. Reverts if any triple in the batch was already paid.
    /// @param _bonusTypes Backend-defined enum encoded as uint8 (e.g. 1 = Marketing, 2 = Support, ...).
    function sendCustomBonusBatch(
        address[] calldata _users,
        uint8[] calldata _bonusTypes,
        uint256[] calldata _campaignIds,
        uint256[] calldata _amounts
    ) external onlyManager nonReentrant {
        uint256 len = _users.length;
        require(len == _bonusTypes.length, "Length mismatch");
        require(len == _campaignIds.length, "Length mismatch");
        require(len == _amounts.length, "Length mismatch");
        require(len <= 200, "Batch too large");

        for (uint256 i = 0; i < len; i++) {
            _sendCustomBonus(_users[i], _bonusTypes[i], _campaignIds[i], _amounts[i]);
        }
    }

    function _sendCustomBonus(
        address _user,
        uint8 _bonusType,
        uint256 _campaignId,
        uint256 _amount
    ) internal {
        require(!killSwitch, "Kill switch is active");
        require(_user != address(0), "Invalid address");
        require(_amount > 0, "Amount is zero");

        bytes32 paymentId = _paymentId(_user, _bonusType, _campaignId);
        require(!bonusPaid[paymentId], "Already paid");
        require(usdc.balanceOf(address(this)) >= _amount, "Insufficient USDC balance");

        bonusPaid[paymentId] = true;
        totalPaid += _amount;
        totalBonusCount++;
        campaignPaid[_bonusType][_campaignId] += _amount;
        campaignBonusCount[_bonusType][_campaignId]++;

        usdc.safeTransfer(_user, _amount);

        emit CustomBonusPaid(paymentId, _user, _bonusType, _campaignId, _amount);
    }

    function _paymentId(address _user, uint8 _bonusType, uint256 _campaignId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_user, _bonusType, _campaignId));
    }

    // ── Admin ──

    function setKillSwitch(bool _enabled) external onlyOwner {
        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    function updateContracts(address _managerRegistry, address _usdc) external onlyOwner {
        if (_managerRegistry != address(0)) managerRegistry = IManagerRegistry(_managerRegistry);
        if (_usdc != address(0)) usdc = IERC20(_usdc);
        emit ContractsUpdated(_managerRegistry, _usdc);
    }

    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        IERC20(_token).safeTransfer(_recipient, _amount);
    }

    // ── Views ──

    function paymentIdOf(address _user, uint8 _bonusType, uint256 _campaignId) external pure returns (bytes32) {
        return _paymentId(_user, _bonusType, _campaignId);
    }

    function isPaid(address _user, uint8 _bonusType, uint256 _campaignId) external view returns (bool) {
        return bonusPaid[_paymentId(_user, _bonusType, _campaignId)];
    }

    function getStats() external view returns (uint256 paid, uint256 count, uint256 balance) {
        return (totalPaid, totalBonusCount, usdc.balanceOf(address(this)));
    }

    function getCampaignStats(uint8 _bonusType, uint256 _campaignId) external view returns (uint256 paid, uint256 count) {
        return (campaignPaid[_bonusType][_campaignId], campaignBonusCount[_bonusType][_campaignId]);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
