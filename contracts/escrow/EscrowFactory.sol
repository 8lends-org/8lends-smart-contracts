// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IManagerRegistry} from "../interfaces/protocol/IManagerRegistry.sol";

import {IEscrowFactory} from "../interfaces/protocol/IEscrowFactory.sol";
import {IAmlEscrow} from "../interfaces/protocol/IAmlEscrow.sol";

/// @title EscrowFactory
/// @notice UUPS upgradeable factory that deploys per-user AmlEscrow minimal proxies via CREATE2.
///         Routes signer calls to individual escrows and holds global configuration.
contract EscrowFactory is Initializable, UUPSUpgradeable, OwnableUpgradeable, IEscrowFactory {
    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    address public implementation;
    address public fundraise;
    address public usdc;
    address public __deprecated_signer;
    uint256 public maxInvestAmount;
    uint256 public minInvestAmount;
    uint256 public refundTimeout;
    mapping(address => address) public escrows;

    /// @notice Holds the operator and admin lists this contract reads.
    address public managerRegistry;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EscrowCreated(address indexed user, address indexed escrow);
    event MaxInvestAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MinInvestAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event RefundTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event ManagerRegistryUpdated(address indexed managerRegistry);
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event FundraiseUpdated(address indexed oldFundraise, address indexed newFundraise);
    event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);

    /// @dev Mirrored from AmlEscrow for single-address indexing
    event InvestRequestedForUser(address indexed user, uint256 indexed pid, uint256 requestId, uint256 amount, address inviter, uint256 createdAt, uint256 cancelAfter);
    event InvestApprovedForUser(address indexed user, uint256 indexed pid, uint256 requestId, uint256 amount, address inviter);
    event InvestRejectedForUser(address indexed user, uint256 indexed pid, uint256 requestId, uint256 amount, address inviter);
    event RequestCancelledForUser(address indexed user, uint256 indexed pid, uint256 requestId, uint256 amount, address inviter);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @notice Initialize the factory proxy
    /// @param _impl      AmlEscrow implementation address
    /// @param _fundraise Fundraise contract address
    /// @param _usdc      USDC token address
    /// @param _managerRegistry Holds the operator and admin lists
    function initialize(
        address _impl,
        address _fundraise,
        address _usdc,
        address _managerRegistry
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        require(_impl != address(0), "Zero address");
        require(_fundraise != address(0), "Zero address");
        require(_usdc != address(0), "Zero address");
        require(_managerRegistry != address(0), "Zero address");

        implementation = _impl;
        fundraise = _fundraise;
        usdc = _usdc;
        managerRegistry = _managerRegistry;

        maxInvestAmount = 500e6;
        minInvestAmount = 1e6;
        refundTimeout = 30 days;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Platform parameters, not wiring and not money.
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner() || IManagerRegistry(managerRegistry).isAdmin(msg.sender), "Not authorized");
        _;
    }

    /// @dev Approving an AML request is the operator role. The registry has to be set before the
    ///      first call — the upgrade and setManagerRegistry belong in one batch, or approvals stop
    ///      in between.
    modifier onlyOperator() {
        require(IManagerRegistry(managerRegistry).isOperator(msg.sender), "Not operator");
        _;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _salt(address _user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_user));
    }

    // -------------------------------------------------------------------------
    // Escrow deployment
    // -------------------------------------------------------------------------

    /// @notice Predict the deterministic address for a user's escrow (before deployment)
    /// @param _user The user address
    /// @return The predicted escrow address
    function getEscrowAddress(address _user) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(_user));
    }

    /// @notice Deploy (or retrieve existing) escrow for a user
    /// @dev Idempotent: returns existing escrow if already deployed
    /// @param _user The user address
    /// @return escrow The escrow address
    function createEscrow(address _user) external returns (address escrow) {
        require(
            msg.sender == _user || IManagerRegistry(managerRegistry).isOperator(msg.sender),
            "Not authorized"
        );

        if (escrows[_user] != address(0)) {
            return escrows[_user];
        }

        escrow = Clones.cloneDeterministic(implementation, _salt(_user));
        escrows[_user] = escrow;
        IAmlEscrow(escrow).initialize(_user, address(this));

        emit EscrowCreated(_user, escrow);
    }

    // -------------------------------------------------------------------------
    // Signer routes
    // -------------------------------------------------------------------------

    /// @notice Approve a pending invest request for a user
    /// @param _user      The user whose escrow to route to
    /// @param _requestId The request index
    function approveInvest(address _user, uint256 _requestId) external onlyOperator {
        address escrow = escrows[_user];
        require(escrow != address(0), "No escrow");
        IAmlEscrow.InvestRequest memory req = IAmlEscrow(escrow).getRequest(_requestId);
        IAmlEscrow(escrow).approveInvest(_requestId);
        emit InvestApprovedForUser(_user, req.pid, _requestId, req.amount, req.inviter);
    }

    /// @notice Reject a pending invest request for a user
    /// @param _user      The user whose escrow to route to
    /// @param _requestId The request index
    function rejectInvest(address _user, uint256 _requestId) external onlyOperator {
        address escrow = escrows[_user];
        require(escrow != address(0), "No escrow");
        IAmlEscrow.InvestRequest memory req = IAmlEscrow(escrow).getRequest(_requestId);
        IAmlEscrow(escrow).rejectInvest(_requestId);
        emit InvestRejectedForUser(_user, req.pid, _requestId, req.amount, req.inviter);
    }

    // -------------------------------------------------------------------------
    // Escrow callbacks (called by AmlEscrow for indexer-friendly events)
    // -------------------------------------------------------------------------

    /// @inheritdoc IEscrowFactory
    function onInvestRequested(
        address _user, uint256 _requestId, uint256 _pid, uint256 _amount, address _inviter, uint256 _createdAt, uint256 _cancelAfter
    ) external {
        require(escrows[_user] == msg.sender, "Not escrow");
        emit InvestRequestedForUser(_user, _pid, _requestId, _amount, _inviter, _createdAt, _cancelAfter);
    }

    /// @inheritdoc IEscrowFactory
    /// @dev The clone calls this at the end of cancelRequest, in the same transaction and after
    ///      the refund, so reverting here reverts the cancellation itself. That is what lets a
    ///      freeze reach escrows already deployed: a minimal clone carries its implementation in
    ///      its own bytecode and can never be upgraded, but the factory it calls back can.
    function onRequestCancelled(
        address _user, uint256 _requestId, uint256 _pid, uint256 _amount, address _inviter
    ) external {
        require(escrows[_user] == msg.sender, "Not escrow");
        require(!IManagerRegistry(managerRegistry).isFrozen(_user), "Account is frozen");

        emit RequestCancelledForUser(_user, _pid, _requestId, _amount, _inviter);
    }

    // -------------------------------------------------------------------------
    // Owner setters
    // -------------------------------------------------------------------------

    function setMaxInvestAmount(uint256 _amount) external onlyOwnerOrAdmin {
        require(_amount > 0 && _amount >= minInvestAmount, "Invalid amount");
        uint256 oldAmount = maxInvestAmount;
        maxInvestAmount = _amount;
        emit MaxInvestAmountUpdated(oldAmount, _amount);
    }

    function setMinInvestAmount(uint256 _amount) external onlyOwnerOrAdmin {
        require(_amount > 0 && _amount <= maxInvestAmount, "Invalid amount");
        uint256 oldAmount = minInvestAmount;
        minInvestAmount = _amount;
        emit MinInvestAmountUpdated(oldAmount, _amount);
    }

    function setRefundTimeout(uint256 _timeout) external onlyOwnerOrAdmin {
        require(_timeout > 0 && _timeout <= 365 days, "Invalid timeout");
        uint256 oldTimeout = refundTimeout;
        refundTimeout = _timeout;
        emit RefundTimeoutUpdated(oldTimeout, _timeout);
    }

    function setImplementation(address _impl) external onlyOwner {
        require(_impl != address(0), "Zero address");
        address oldImpl = implementation;
        implementation = _impl;
        emit ImplementationUpdated(oldImpl, _impl);
    }

    function setManagerRegistry(address _managerRegistry) external onlyOwner {
        require(_managerRegistry != address(0), "Zero address");
        managerRegistry = _managerRegistry;
        emit ManagerRegistryUpdated(_managerRegistry);
    }

    function setFundraise(address _fundraise) external onlyOwner {
        require(_fundraise != address(0), "Zero address");
        address oldFundraise = fundraise;
        fundraise = _fundraise;
        emit FundraiseUpdated(oldFundraise, _fundraise);
    }

    function setUsdc(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Zero address");
        address oldUsdc = usdc;
        usdc = _usdc;
        emit UsdcUpdated(oldUsdc, _usdc);
    }

    // -------------------------------------------------------------------------
    // UUPS authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
