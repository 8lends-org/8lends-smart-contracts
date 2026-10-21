// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title IMandateRouter
/// @notice Holds payout routes and the per-escrow list of enrolled projects. Upgradeable.
/// @dev No accounting state: a payout is split into principal and interest inside the payout
///      transaction itself, by the escrow's onPayout.
interface IMandateRouter {
    /// @notice Emitted on every route change, including overwrites and clears.
    /// @dev escrow == 0 means the route was cleared; a non-zero previous means it was moved.
    event RouteSet(address indexed owner, uint256 indexed pid, address escrow, address previous);

    // ── views ───────────────────────────────────────────────────────────────────

    /// @notice Where payouts for this owner's position in this project go. Zero means the wallet.
    /// @dev One route per project. Fundraise reads this to pick the payout target, so a caller
    ///      never has to work out which of an owner's mandates a project belongs to.
    function routes(address owner, uint256 pid) external view returns (address escrow);

    /// @notice Projects whose payouts are routed to this escrow.
    function enrolledPids(address escrow) external view returns (uint256[] memory);

    /// @notice The registry this router reads. Two things come from it: isOperator for clearIfEmpty
    ///         and the factory address for the ownership check.
    /// @dev A zero or wrong value here reverts setRoute, setRouteMany and enrollSelf — worth
    ///      checking before a release.
    function managerRegistry() external view returns (address);

    /// @notice The Fundraise this router reads investorInfo from.
    function fundraise() external view returns (address);

    /// @notice Outstanding principal across every project of this escrow — the mandate's size,
    ///         less what is sitting on its balance.
    /// @dev Walks the enrolled list, so it costs a Fundraise read per project. What was claimed is
    ///      split by the same interest-first waterfall onPayout applies, since totalClaimed mixes
    ///      the two and only the principal part of it has left the mandate.
    function outstanding(address escrow) external view returns (uint256 total);

    /// @notice Outstanding principal of this escrow in one project. Constant time.
    /// @dev Zero for a project that is not enrolled, even when the owner holds a manual position
    ///      there: this is how much of the mandate is in the project, not how much of the owner.
    function exposure(address escrow, uint256 pid) external view returns (uint256);

    // ── owner ───────────────────────────────────────────────────────────────────

    /// @notice Routes a project's payouts to the escrow. Works on projects that already hold manual
    ///         positions — the whole project moves, including shares bought on the secondary market.
    /// @dev The only check is that the target is an escrow of msg.sender. No signature, no
    ///      emptiness check, and the project's loanToken is not verified: the escrow only handles
    ///      USDC, so projects denominated in anything else must be filtered off chain.
    /// @dev Not retroactive: already claimed payouts stay where they went. Only what is claimed
    ///      after the route is set reaches the escrow.
    function setRoute(uint256 pid, address escrow) external;

    /// @notice Same for many projects at once. One call regardless of count — this is what moves
    ///         positions when a user migrates to a new mandate.
    /// @dev Reverts as a whole if any element fails, so filter the list before sending.
    function setRouteMany(uint256[] calldata pids, address escrow) external;

    /// @notice Sends payouts for this project back to the wallet. Unconditional: detaching must
    ///         never be blockable, so there is no gate beyond "a route exists".
    /// @dev While detached, payouts reach the wallet unclassified — onPayout is not called, so
    ///      interest is not forwarded per interestDirection.
    function detach(uint256 pid) external;

    // ── escrow ──────────────────────────────────────────────────────────────────

    /// @notice Called by an escrow to route a project to itself during allocation.
    /// @dev Reverts when the owner already has a position in this project: a mandate must not
    ///      capture manual shares on its own initiative. The owner unblocks it with setRoute.
    function enrollSelf(uint256 pid) external;

    // ── operator ────────────────────────────────────────────────────────────────

    /// @notice Clears the route once nothing is left in the project. Keeps the enrolled list short,
    ///         which is what keeps allocation gas bounded.
    /// @dev Operator-gated, and it requires two things on chain: no outstanding principal, and a
    ///      project that is Repaid or Canceled. Outstanding alone would not do — a position that is
    ///      merely listed on the market also reads as zero.
    /// @dev CALLER CONTRACT: those two are still not the whole condition. An owner who listed ALL
    ///      positions in a project looks like one who left it, so clearing then means their lots
    ///      come back without a route and payouts go to the wallet. "No active lots on this
    ///      project" cannot be checked on chain (Market has no aggregate counter;
    ///      activePositionSaleIds is keyed by position index), so the caller must check it.
    function clearIfEmpty(address owner, uint256 pid) external;

    /// @notice Same for many (owner, project) pairs. Reverts as a whole if any element fails.
    function clearIfEmptyMany(address[] calldata owners, uint256[] calldata pids) external;
}
