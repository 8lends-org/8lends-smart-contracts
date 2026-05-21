// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAmlEscrow} from "./interfaces/IAmlEscrow.sol";
import {IEscrowFactory} from "./interfaces/IEscrowFactory.sol";

// ---------------------------------------------------------------------------
// Inline external interfaces
// (IFundraise stays inline; IEscrowFactory now imported from ./interfaces/IEscrowFactory.sol)
// ---------------------------------------------------------------------------

interface IFundraise {
    function investFromEscrow(
        address investor,
        uint256 pid,
        uint256 amount,
        address inviter
    ) external;
}

// ---------------------------------------------------------------------------
// AmlEscrow
// ---------------------------------------------------------------------------

/// @title AmlEscrow
/// @notice Per-user escrow wallet. The user calls invest() to lock USDC and
///         create a Pending request. The factory backend then calls
///         approveInvest() or rejectInvest() to settle each request.
///         Implements EIP-1167 minimal-proxy pattern (no constructors with
///         logic — use initialize() instead).
contract AmlEscrow is IAmlEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    address public user;
    address public factory;

    InvestRequest[] public requests;

    bool private _initialized;

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @inheritdoc IAmlEscrow
    function initialize(address _user, address _factory) external {
        require(!_initialized, "Already initialized");
        require(_user != address(0) && _factory != address(0), "Zero address");
        user = _user;
        factory = _factory;
        _initialized = true;
    }

    // -------------------------------------------------------------------------
    // User actions
    // -------------------------------------------------------------------------

    /// @inheritdoc IAmlEscrow
    function invest(
        uint256 pid,
        uint256 amount,
        address inviter
    ) external nonReentrant {
        require(msg.sender == user, "Not user");

        IEscrowFactory f = IEscrowFactory(factory);
        require(amount >= f.minInvestAmount(), "Below minimum");
        require(amount <= f.maxInvestAmount(), "Above maximum");

        IERC20 usdc = IERC20(f.usdc());
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 requestId = requests.length;
        uint256 cancelAfter = block.timestamp + IEscrowFactory(factory).refundTimeout();
        requests.push(
            InvestRequest({
                pid: pid,
                amount: amount,
                inviter: inviter,
                createdAt: block.timestamp,
                cancelAfter: cancelAfter,
                status: RequestStatus.Pending
            })
        );

        emit InvestRequested(user, requestId, pid, amount, inviter, block.timestamp, cancelAfter);
    }

    /// @inheritdoc IAmlEscrow
    function cancelRequest(uint256 requestId) external nonReentrant {
        require(msg.sender == user, "Not user");

        InvestRequest storage req = requests[requestId];
        require(req.status == RequestStatus.Pending, "Not pending");

        require(block.timestamp >= req.cancelAfter, "Too early");

        req.status = RequestStatus.Cancelled;

        IERC20(IEscrowFactory(factory).usdc()).safeTransfer(user, req.amount);

        emit RequestCancelled(user, requestId, req.pid, req.amount, req.inviter);
    }

    // -------------------------------------------------------------------------
    // Factory-only actions
    // -------------------------------------------------------------------------

    /// @inheritdoc IAmlEscrow
    function approveInvest(uint256 requestId) external nonReentrant {
        require(msg.sender == factory, "Not factory");

        InvestRequest storage req = requests[requestId];
        require(req.status == RequestStatus.Pending, "Not pending");

        IEscrowFactory f = IEscrowFactory(factory);
        address fundraise = f.fundraise();
        IERC20 usdc = IERC20(f.usdc());

        // CEI: status update happens AFTER the external call succeeds.
        // forceApprove sets exact value; safe to call repeatedly (fixes Slither S-1).
        usdc.forceApprove(fundraise, req.amount);

        // External call — if this reverts, the whole tx reverts and the request
        // remains Pending (retryable). Status is therefore set only on success.
        IFundraise(fundraise).investFromEscrow(
            user,
            req.pid,
            req.amount,
            req.inviter
        );

        // Clear residual allowance in case Fundraise consumed less than approved
        usdc.forceApprove(fundraise, 0);

        req.status = RequestStatus.Approved;

        emit InvestApproved(user, requestId, req.pid, req.amount, req.inviter);
    }

    /// @inheritdoc IAmlEscrow
    function rejectInvest(uint256 requestId) external nonReentrant {
        require(msg.sender == factory, "Not factory");

        InvestRequest storage req = requests[requestId];
        require(req.status == RequestStatus.Pending, "Not pending");

        // CEI: set terminal status before external transfer
        req.status = RequestStatus.Rejected;

        IERC20(IEscrowFactory(factory).usdc()).safeTransfer(user, req.amount);

        emit InvestRejected(user, requestId, req.pid, req.amount, req.inviter);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @inheritdoc IAmlEscrow
    function getRequestCount() external view returns (uint256) {
        return requests.length;
    }

    /// @inheritdoc IAmlEscrow
    function getRequest(uint256 requestId) external view returns (InvestRequest memory) {
        return requests[requestId];
    }

    /// @inheritdoc IAmlEscrow
    function getRequests(
        uint256 fromIndex,
        uint256 count
    ) external view returns (InvestRequest[] memory result) {
        uint256 len = requests.length;
        if (fromIndex >= len) return new InvestRequest[](0);

        uint256 end = fromIndex + count;
        if (end > len) end = len;

        result = new InvestRequest[](end - fromIndex);
        for (uint256 i = fromIndex; i < end; i++) {
            result[i - fromIndex] = requests[i];
        }
    }
}
