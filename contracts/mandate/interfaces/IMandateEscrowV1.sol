// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ImmutableParamsV1, MandateState } from "./MandateTypes.sol";

/// @title IMandateEscrowV1
/// @notice Per-user, non-upgradeable escrow: free USDC, rules, allocation, withdrawal.
///         One clone per (owner, params, implementation version).
/// @dev Kept here is only what a
///      caller cannot infer from the signatures.
interface IMandateEscrowV1 {
    // ── events ──────────────────────────────────────────────────────────────────

    /// @notice Placement into a project. This, not the transaction receipt, confirms one happened:
    ///         Fundraise._invest can return false without reverting.
    /// @param paramsHash Snapshot of the rules the mandate was created with
    /// @param inviter Referral passed by the backend; zero outside the 45-day window
    event Allocated(uint256 indexed pid, uint256 amount, bytes32 paramsHash, address inviter);

    /// @notice A payout split into principal (left on the balance) and interest (routed per rule).
    event PayoutSplit(uint256 indexed pid, uint256 principal, uint256 interest);

    /// @notice Interest sent out: to the wallet (direction 1) or into lending (2).
    /// @dev Not one-to-one with PayoutSplit — silent under direction 0 and on zero interest.
    /// @param recipient The transfer target, not the beneficiary. Under direction 2 it is Lending8
    ///        itself; the position belongs to owner(), which is where to read the beneficiary.
    event InterestForwarded(uint8 direction, uint256 amount, address recipient);

    event Deposited(address indexed from, uint256 amount);

    /// @notice Anything leaving by the owner's own call.
    /// @dev `token` is indexed and not optional for the indexer: without it, capital leaving the
    ///      mandate is indistinguishable from rescuing a stray token.
    event Withdrawn(address indexed to, address indexed token, uint256 amount);

    event StateChanged(MandateState state);

    /// @notice Free balance rescued to the claim address after a wallet compromise.
    event SweptToClaimAddress(address indexed to, uint256 amount);

    // ── factory only ────────────────────────────────────────────────────────────

    /// @notice Sets the owner and the two rules, in the same transaction as the clone's deployment.
    /// @dev Guarded by `owner == 0` rather than by a caller check — the escrow holds no factory
    ///      address. There is no window: creation and initialisation are one transaction, and the
    ///      clone's address is reachable only by the factory that salted it.
    function initialize(address owner_, ImmutableParamsV1 calldata params_) external;

    // ── views ───────────────────────────────────────────────────────────────────

    function owner() external view returns (address);
    function version() external view returns (uint16);
    function state() external view returns (MandateState);

    /// @notice keccak of ImmutableParamsV1, and part of the escrow address.
    function paramsHash() external view returns (bytes32);

    /// @notice Both rules. Nothing about a mandate changes after creation, so this is safe to cache
    ///         against the escrow address — there is no mutable counterpart.
    function params() external view returns (ImmutableParamsV1 memory);

    /// @notice USDC the mandate may place; the escrow's balance in v1.
    /// @dev Read this rather than the token balance — a later version need not answer with the raw
    ///      balance.
    function freeBalance() external view returns (uint256);

    /// @notice freeBalance() plus outstanding principal, the base the per-project limit is taken
    ///         from. Moves as payouts come in.
    function mandateSize() external view returns (uint256);

    /// @notice What the limit allows for one project right now.
    /// @dev `room` is NOT what allocate() will place: below minAllocation() it is raised to that
    ///      minimum. Do not show it to the user as "what goes into this project".
    /// @return cap mandateSize * projectLimitBps / 10000
    /// @return exposure Owner's outstanding principal already in this project
    /// @return room cap - exposure, floored at zero
    function projectLimit(uint256 pid) external view returns (uint256 cap, uint256 exposure, uint256 room);

    /// @notice Smallest amount this mandate will place, and the threshold below which a project is
    ///         skipped.
    /// @dev Not settable: a movable floor would let the platform place past the owner's own
    ///      concentration limit. Read it, do not hardcode a copy — a later version may differ.
    function minAllocation() external view returns (uint256);

    // ── owner ───────────────────────────────────────────────────────────────────

    /// @notice The only top-up path: the owner signs an EIP-3009 authorization and this hands it to
    ///         USDC, which moves the funds. No allowance involved.
    /// @dev Callable by anyone — the only ungated function here, and safe because nothing is the
    ///      caller's choice: `from` is hardwired to owner() and `to` to this escrow, both covered by
    ///      the signature. A relayer can pay the gas; a third party can only pick the moment inside
    ///      the window. `receiveWithAuthorization` additionally requires msg.sender == to, so the
    ///      authorization cannot be spent anywhere else and money can never arrive while this
    ///      contract's bookkeeping is skipped.
    /// @param value Exact amount; the signature fixes it
    /// @param validAfter Unix seconds, exclusive; 0 for "immediately"
    /// @param validBefore Unix seconds, exclusive. Set now + 600…900. The window is the only
    ///        revocation there is — cancelAuthorization needs another signature from the owner.
    /// @param nonce 32 bytes unique per owner, in its own namespace, so nothing needs reading from
    ///        chain before signing. Use keccak256(abi.encode(uint256(intentId))) so uniqueness comes
    ///        from a database constraint. Doubles as an idempotency key:
    ///        USDC.authorizationState(owner, nonce) answers "did this deposit land".
    /// @dev Expiry does not consume the nonce — only success or cancelAuthorization does. After an
    ///      "expired" revert the same nonce can be re-signed with a fresh validBefore.
    /// @param sig EIP-712 signature, bytes form, so EIP-1271 smart accounts work too
    function depositWithAuthorization(
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata sig
    ) external;

    /// @notice Unconditional: no backend signature, no manager approval, any state. Pays to the
    ///         claim address if the wallet is flagged as compromised.
    /// @dev The token is an argument rather than hardwired to USDC so that anything landing here can
    ///      leave — a payout in another token, an airdrop, a mistaken transfer. An immutable clone
    ///      cannot gain a rescue function later, which is why it is here from v1.
    function withdraw(address token, uint256 amount) external;

    /// @notice Full balance of that token. Same guard and recipient as withdraw.
    function withdrawAll(address token) external;

    function pause() external;
    function resume() external;

    // ── owner, claim address or operator ────────────────────────────────────────

    /// @notice Moves the free balance to the recovery address recorded in ManagerRegistry.
    /// @dev One gate: isCompromised(owner) must be true — a revert, not a soft condition, or anyone
    ///      could drain a healthy mandate onto its owner's wallet and stop it re-placing.
    /// @dev Callable by anyone past that. The caller chooses nothing: the recipient is always
    ///      recipientOf(owner) and the amount is the whole free balance. On the recovery path that
    ///      is worth more than a caller list — the owner's key is untrusted, the recovery address may
    ///      be cold, and the operator may be down or revoked.
    function sweepToClaimAddress() external;

    // ── operator (backend) ──────────────────────────────────────────────────────

    /// @notice Places free USDC into a project. The caller cannot choose the amount:
    ///           want   = (exposure == 0 && room < minAllocation()) ? minAllocation() : room
    ///           amount = min(want, project free capacity, freeBalance())
    /// @dev The floor applies to a FIRST entry only. On a top-up placing does not change
    ///      mandateSize — money moves from free balance to outstanding — so cap stays put and room
    ///      is zero from the second pass on. An unconditional floor would pour the whole balance
    ///      into one project ticket by ticket and the per-project limit would cease to exist.
    /// @dev Reverts when: paused, project not Open, the computed amount is below minAllocation, the
    ///      project is routed to another escrow of the same owner, the owner already holds it
    ///      manually (enrollSelf refuses), or the reward system cannot price the platform token. The
    ///      allocator must filter the first two cases itself and retry on a limit revert — mandate
    ///      size can change between computing and sending.
    /// @param inviter Referral while the 45-day window is open, zero after. The window exists only
    ///        in the backend; this argument is the only lever, and zero skips both the permanent
    ///        inviter binding and the accrual. Unlike the manual path it is not part of a signed
    ///        preimage, and the binding is irreversible.
    function allocate(uint256 pid, address inviter) external;

    // ── Fundraise only ──────────────────────────────────────────────────────────

    /// @notice Called by Fundraise right after a payout landed here. Splits it into principal and
    ///         interest and forwards the interest per the mandate's rule.
    /// @dev The split rule lives in this clone, not in Fundraise, so "how my interest is computed"
    ///      cannot change by upgrade. Interest-first waterfall: budget = invested * rate / 10000,
    ///      position before this payout = claimed - fresh.
    /// @dev Called from claimForMandate only, and it must call ONLY when the payout target is this
    ///      escrow by route and the payout is non-zero. Not "target != investor": the compromise
    ///      branch also differs from the investor with no escrow involved, and a void call to an EOA
    ///      does not revert, so that mistake would be silent. Since this sits in the payout path, a
    ///      revert here blocks payouts for the mandate and cannot be patched.
    /// @param fresh How much just arrived — only the payer knows it; everyone else sees the
    ///        cumulative total and cannot tell a payout that arrived now from one a month ago
    /// @param claimed Owner's totalClaimed AFTER the increment
    /// @param rate Project's investorInterestRate, passed because Fundraise already has it
    /// @param marketId Lending8 pool for direction 2, ignored under 0 and 1 but always passed
    ///        because the caller does not know the direction. Zero reverts under 2. An argument
    ///        rather than a constant of the clone so a second pool costs nothing on chain; the cost
    ///        is that a hot key picks the pool on every payout.
    function onPayout(
        uint256 pid,
        uint256 fresh,
        uint256 invested,
        uint256 claimed,
        uint256 rate,
        bytes32 marketId
    ) external;
}
