// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title IAmlEscrow
/// @notice Public interface for the per-user AML escrow contract
interface IAmlEscrow {
    // -------------------------------------------------------------------------
    // Enums & Structs
    // -------------------------------------------------------------------------

    enum RequestStatus {
        Pending,
        Approved,
        Rejected,
        Cancelled
    }

    struct InvestRequest {
        uint256 pid;
        uint256 amount;
        address inviter;
        uint256 createdAt;
        RequestStatus status;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event InvestRequested(
        address indexed user,
        uint256 indexed requestId,
        uint256 pid,
        uint256 amount,
        address inviter
    );

    event InvestApproved(
        address indexed user,
        uint256 indexed requestId,
        uint256 pid,
        uint256 amount
    );

    event InvestRejected(
        address indexed user,
        uint256 indexed requestId,
        uint256 pid,
        uint256 amount
    );

    event RequestCancelled(
        address indexed user,
        uint256 indexed requestId,
        uint256 pid,
        uint256 amount
    );

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @notice Initialize the escrow proxy (called once by factory)
    /// @param _user  The user that owns this escrow
    /// @param _factory The factory that manages this escrow
    function initialize(address _user, address _factory) external;

    // -------------------------------------------------------------------------
    // User actions
    // -------------------------------------------------------------------------

    /// @notice Pull USDC from msg.sender and create a Pending invest request
    /// @param pid     Project id to invest in
    /// @param amount  USDC amount (must be within [min, max] from factory)
    /// @param inviter Referral address (zero = no referrer)
    function invest(uint256 pid, uint256 amount, address inviter) external;

    /// @notice Cancel a Pending request after the refund timeout has elapsed
    /// @param requestId Index in the requests array
    function cancelRequest(uint256 requestId) external;

    // -------------------------------------------------------------------------
    // Factory-only actions
    // -------------------------------------------------------------------------

    /// @notice Forward a Pending request to Fundraise; status -> Approved on success
    /// @param requestId Index in the requests array
    function approveInvest(uint256 requestId) external;

    /// @notice Reject a Pending request and return USDC to user; status -> Rejected
    /// @param requestId Index in the requests array
    function rejectInvest(uint256 requestId) external;

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function user() external view returns (address);
    function factory() external view returns (address);

    function getRequestCount() external view returns (uint256);
    function getRequest(uint256 requestId) external view returns (InvestRequest memory);

    /// @notice Paginated batch getter
    /// @param fromIndex Start index (inclusive)
    /// @param count     Maximum number of entries to return
    function getRequests(uint256 fromIndex, uint256 count) external view returns (InvestRequest[] memory);
}
