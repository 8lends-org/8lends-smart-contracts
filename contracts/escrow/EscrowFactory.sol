// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IEscrowFactory} from "./interfaces/IEscrowFactory.sol";
import {IAmlEscrow} from "./interfaces/IAmlEscrow.sol";

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
    address public signer;
    uint256 public maxInvestAmount;
    uint256 public minInvestAmount;
    uint256 public refundTimeout;
    mapping(address => address) public escrows;

    /// @dev Reserved storage gap for future upgrades
    uint256[50] private __gap;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EscrowCreated(address indexed user, address escrow);
    event SignerUpdated(address signer);
    event MaxInvestAmountUpdated(uint256 amount);
    event MinInvestAmountUpdated(uint256 amount);
    event RefundTimeoutUpdated(uint256 timeout);
    event ImplementationUpdated(address implementation);
    event FundraiseUpdated(address fundraise);
    event UsdcUpdated(address usdc);

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
    /// @param _signer    Backend signer address
    function initialize(
        address _impl,
        address _fundraise,
        address _usdc,
        address _signer
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        require(_impl != address(0), "Zero address");
        require(_fundraise != address(0), "Zero address");
        require(_usdc != address(0), "Zero address");
        require(_signer != address(0), "Zero address");

        implementation = _impl;
        fundraise = _fundraise;
        usdc = _usdc;
        signer = _signer;

        maxInvestAmount = 500e6;
        minInvestAmount = 1e6;
        refundTimeout = 30 days;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlySigner() {
        require(msg.sender == signer, "Not signer");
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
        require(msg.sender == _user || msg.sender == signer, "Not authorized");

        if (escrows[_user] != address(0)) {
            return escrows[_user];
        }

        escrow = Clones.cloneDeterministic(implementation, _salt(_user));
        IAmlEscrow(escrow).initialize(_user, address(this));
        escrows[_user] = escrow;

        emit EscrowCreated(_user, escrow);
    }

    // -------------------------------------------------------------------------
    // Signer routes
    // -------------------------------------------------------------------------

    /// @notice Approve a pending invest request for a user
    /// @param _user      The user whose escrow to route to
    /// @param _requestId The request index
    function approveInvest(address _user, uint256 _requestId) external onlySigner {
        address escrow = escrows[_user];
        require(escrow != address(0), "No escrow");
        IAmlEscrow(escrow).approveInvest(_requestId);
    }

    /// @notice Reject a pending invest request for a user
    /// @param _user      The user whose escrow to route to
    /// @param _requestId The request index
    function rejectInvest(address _user, uint256 _requestId) external onlySigner {
        address escrow = escrows[_user];
        require(escrow != address(0), "No escrow");
        IAmlEscrow(escrow).rejectInvest(_requestId);
    }

    // -------------------------------------------------------------------------
    // Owner setters
    // -------------------------------------------------------------------------

    function setSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "Zero address");
        signer = _signer;
        emit SignerUpdated(_signer);
    }

    function setMaxInvestAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0 && _amount >= minInvestAmount, "Invalid amount");
        maxInvestAmount = _amount;
        emit MaxInvestAmountUpdated(_amount);
    }

    function setMinInvestAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0 && _amount <= maxInvestAmount, "Invalid amount");
        minInvestAmount = _amount;
        emit MinInvestAmountUpdated(_amount);
    }

    function setRefundTimeout(uint256 _timeout) external onlyOwner {
        require(_timeout > 0 && _timeout <= 365 days, "Invalid timeout");
        refundTimeout = _timeout;
        emit RefundTimeoutUpdated(_timeout);
    }

    function setImplementation(address _impl) external onlyOwner {
        require(_impl != address(0), "Zero address");
        implementation = _impl;
        emit ImplementationUpdated(_impl);
    }

    function setFundraise(address _fundraise) external onlyOwner {
        require(_fundraise != address(0), "Zero address");
        fundraise = _fundraise;
        emit FundraiseUpdated(_fundraise);
    }

    function setUsdc(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Zero address");
        usdc = _usdc;
        emit UsdcUpdated(_usdc);
    }

    // -------------------------------------------------------------------------
    // UUPS authorization
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
