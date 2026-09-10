// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/protocol/IManagerRegistry.sol";

/// @title CryptoCourseBonus
/// @notice USDC bonus per completed course. Two rewards with their own amounts and entry points:
/// cash, paid straight away, and voucher, paid at maturity. Whichever comes first, a wallet is paid
/// once per course and never again.
/// @dev Pushed by an operator, so the user pays no gas and there is no user-facing entry point.
contract CryptoCourseBonus is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IManagerRegistry public managerRegistry;
    IERC20 public usdc;

    bool public killSwitch;

    /// @notice Cash reward per course, e.g. 15e6 for 15 USDC. Zero means this course has no cash
    ///         reward — which is also how an unknown course behaves, without a separate registry,
    ///         and how a reward is retired.
    mapping(uint256 => uint256) public cashAmount;

    /// @notice Voucher reward per course, independent of the cash one: normally larger, and set or
    ///         retired on its own.
    mapping(uint256 => uint256) public voucherAmount;

    /// @notice Whether this wallet was already paid for this course, in either form. Shared by both
    ///         entry points on purpose — the rule is one bonus per course per wallet, so paying the
    ///         cash reward closes the voucher for the same course and the other way round.
    /// @dev Keyed by the pair: a flag per wallet would close every remaining course after the first
    ///      payout.
    mapping(address => mapping(uint256 => bool)) public paid;

    uint256 public totalPaid;
    uint256 public totalBonusCount;

    event CashBonusPaid(address indexed user, uint256 indexed courseId, uint256 amount);
    event VoucherBonusPaid(address indexed user, uint256 indexed courseId, uint256 amount);
    event CashAmountSet(uint256 indexed courseId, uint256 amount);
    event VoucherAmountSet(uint256 indexed courseId, uint256 amount);
    event KillSwitchSet(bool enabled);
    event ContractsUpdated(address managerRegistry, address usdc);
    event Withdrawn(address token, uint256 amount, address recipient);

    error NotOperator();
    error PayoutsStopped();
    error AlreadyPaid(address user, uint256 courseId);
    error RewardNotConfigured(uint256 courseId);
    error InsufficientBalance(uint256 needed, uint256 available);
    error ZeroAddress();
    error LengthMismatch();
    error EmptyBatch();

    modifier onlyOperator() {
        if (!managerRegistry.isOperator(msg.sender)) revert NotOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _managerRegistry, address _usdc) public initializer {
        if (_managerRegistry == address(0) || _usdc == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        managerRegistry = IManagerRegistry(_managerRegistry);
        usdc = IERC20(_usdc);
    }

    // --- Payouts ---

    /// @notice Pays the cash reward for one course to `_user`.
    function sendCashBonus(address _user, uint256 _courseId) external onlyOperator nonReentrant {
        uint256 amount = cashAmount[_courseId];
        _pay(_user, _courseId, amount);
        emit CashBonusPaid(_user, _courseId, amount);
    }

    /// @notice Pays the voucher reward for one course to `_user`.
    function sendVoucherBonus(address _user, uint256 _courseId) external onlyOperator nonReentrant {
        uint256 amount = voucherAmount[_courseId];
        _pay(_user, _courseId, amount);
        emit VoucherBonusPaid(_user, _courseId, amount);
    }

    /// @notice Pays voucher rewards for many (wallet, course) pairs in one transaction — vouchers
    ///         mature in groups, so this is the shape that flow actually has.
    function sendVoucherBonusBatch(address[] calldata _users, uint256[] calldata _courseIds)
        external
        onlyOperator
        nonReentrant
    {
        if (_users.length != _courseIds.length) revert LengthMismatch();
        if (_users.length == 0) revert EmptyBatch();

        for (uint256 i = 0; i < _users.length; i++) {
            uint256 amount = voucherAmount[_courseIds[i]];
            _pay(_users[i], _courseIds[i], amount);
            emit VoucherBonusPaid(_users[i], _courseIds[i], amount);
        }
    }

    function _pay(address _user, uint256 _courseId, uint256 _amount) private {
        if (killSwitch) revert PayoutsStopped();
        if (_user == address(0)) revert ZeroAddress();
        if (paid[_user][_courseId]) revert AlreadyPaid(_user, _courseId);
        if (_amount == 0) revert RewardNotConfigured(_courseId);

        uint256 balance = usdc.balanceOf(address(this));
        if (balance < _amount) revert InsufficientBalance(_amount, balance);

        paid[_user][_courseId] = true;
        totalPaid += _amount;
        totalBonusCount++;

        usdc.safeTransfer(_user, _amount);
    }

    // --- Admin functions ---

    /// @notice Sets the cash reward for a course. Zero retires it: payouts start reverting.
    function setCashAmount(uint256 _courseId, uint256 _amount) external onlyOwner {
        cashAmount[_courseId] = _amount;
        emit CashAmountSet(_courseId, _amount);
    }

    /// @notice Sets the voucher reward for a course. Zero retires it.
    function setVoucherAmount(uint256 _courseId, uint256 _amount) external onlyOwner {
        voucherAmount[_courseId] = _amount;
        emit VoucherAmountSet(_courseId, _amount);
    }

    function setKillSwitch(bool _enabled) external onlyOwner {
        killSwitch = _enabled;
        emit KillSwitchSet(_enabled);
    }

    /// @notice Repoints the registry or the token. A zero leaves that one alone, as in the sibling
    ///         bonus contracts. Revoking one operator is a registry call, not a call here.
    function updateContracts(address _managerRegistry, address _usdc) external onlyOwner {
        if (_managerRegistry != address(0)) managerRegistry = IManagerRegistry(_managerRegistry);
        if (_usdc != address(0)) usdc = IERC20(_usdc);

        emit ContractsUpdated(address(managerRegistry), address(usdc));
    }

    function withdraw(address _token, uint256 _amount, address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_recipient, _amount);

        emit Withdrawn(_token, _amount, _recipient);
    }

    // --- View functions ---

    /// @notice Stats for the admin dashboard.
    function getStats() external view returns (uint256 paidTotal, uint256 count, uint256 balance) {
        return (totalPaid, totalBonusCount, usdc.balanceOf(address(this)));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
