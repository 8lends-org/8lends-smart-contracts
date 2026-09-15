// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IMandateEscrowV1 } from "./interfaces/IMandateEscrowV1.sol";
import { IMandateFundraise } from "./interfaces/IMandateFundraise.sol";
import { IMandateRouter } from "./interfaces/IMandateRouter.sol";
import { ImmutableParamsV1, InterestDirection, MandateState } from "./interfaces/MandateTypes.sol";
import { IERC3009 } from "../interfaces/token/IERC3009.sol";
import { IFundraise } from "../interfaces/protocol/IFundraise.sol";
import { IManagerRegistry } from "../interfaces/protocol/IManagerRegistry.sol";
import { ILending8, Id, MarketParams } from "../lending/interfaces/ILending8.sol";

/// @title MandateEscrowV1
/// @notice One escrow per (owner, params). Holds the mandate's free USDC, computes how much may go
///         into a project, and splits incoming payouts into principal and interest.
/// @dev An EIP-1167 clone, NOT upgradeable — the rules the owner picked are enforced by code that
///      cannot be changed under them. Anything missing arrives only as V2 at a new address.
/// @dev Clones share this bytecode, so everything shared lives in `immutable` and only the
///      per-owner rules take storage — all four fields in one slot.
contract MandateEscrowV1 is IMandateEscrowV1 {
    using SafeERC20 for IERC20;

    // ── constants ───────────────────────────────────────────────────────────────

    uint256 private constant BPS = 10_000;

    /// @dev Smallest ticket, 6 decimals. Not settable: a movable floor would let the platform place
    ///      past the owner's own concentration limit.
    uint256 private constant MIN_ALLOCATION = 100e6;

    // ── immutables (shared by every clone, read from the implementation's code) ──

    address public immutable USDC;
    address public immutable FUNDRAISE;
    address public immutable MANAGER_REGISTRY;
    address public immutable ROUTER;
    address public immutable LENDING8;

    // ── storage (one slot: 20 + 1 + 2 + 1 = 24 bytes) ───────────────────────────
    //
    // Spelled out rather than held as an ImmutableParamsV1 field, which would cost five slots — the
    // owner pays the difference, ~66k gas, on every mandate creation.

    address public owner;
    uint8 private _interestDirection;
    uint16 private _projectLimitBps;
    MandateState public state;

    // ── errors ──────────────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error ZeroAddress();
    error BadInterestDirection(uint8 direction);
    error BadProjectLimitBps(uint16 bps);
    error NotOwner();
    error NotOperator();
    error NotFundraise();
    error NotCompromised();
    error NotActive();
    error ProjectNotOpen();
    error BelowMinimum(uint256 amount);
    error RoutedElsewhere(address routed);
    error NothingToSweep();
    error ZeroMarketId();
    error MarketLoanTokenNotUsdc(address loanToken);

    // ── construction ────────────────────────────────────────────────────────────

    constructor(
        address usdc,
        address fundraise,
        address managerRegistry,
        address router,
        address lending8
    ) {
        if (
            usdc == address(0) ||
            fundraise == address(0) ||
            managerRegistry == address(0) ||
            router == address(0) ||
            lending8 == address(0)
        ) revert ZeroAddress();

        USDC = usdc;
        FUNDRAISE = fundraise;
        MANAGER_REGISTRY = managerRegistry;
        ROUTER = router;
        LENDING8 = lending8;
    }

    /// @notice Sets the owner and the two rules. Called by the factory in the same transaction as
    ///         the clone's deployment.
    /// @dev Guarded by `owner == 0`, not by a caller check, since the escrow holds no factory
    ///      address. No window to exploit: creation and initialisation are one transaction.
    ///      Initialising the implementation itself is harmless — it holds no funds and clones read
    ///      their own storage.
    /// @dev Bounds re-checked despite the factory checking them: the clone is immutable, so a bad
    ///      value written now can never be corrected.
    function initialize(address owner_, ImmutableParamsV1 calldata params_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        if (params_.interestDirection > uint8(type(InterestDirection).max)) {
            revert BadInterestDirection(params_.interestDirection);
        }
        if (params_.projectLimitBps == 0 || params_.projectLimitBps > BPS) {
            revert BadProjectLimitBps(params_.projectLimitBps);
        }

        owner = owner_;
        _interestDirection = params_.interestDirection;
        _projectLimitBps = params_.projectLimitBps;
        // state stays MandateState.ACTIVE — the zero value, so no SSTORE.
    }

    // ── modifiers ───────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!IManagerRegistry(MANAGER_REGISTRY).isOperator(msg.sender)) revert NotOperator();
        _;
    }

    // ── views ───────────────────────────────────────────────────────────────────

    function version() external pure returns (uint16) {
        return 1;
    }

    function params() external view returns (ImmutableParamsV1 memory) {
        return ImmutableParamsV1(_interestDirection, _projectLimitBps);
    }

    /// @dev Computed, not stored: a copy would cost a cold SSTORE and buy nothing. The encoding must
    ///      stay byte-for-byte the factory's — this hash goes into the escrow address.
    function paramsHash() public view returns (bytes32) {
        return keccak256(abi.encode(ImmutableParamsV1(_interestDirection, _projectLimitBps)));
    }

    function freeBalance() public view returns (uint256) {
        return IERC20(USDC).balanceOf(address(this));
    }

    function minAllocation() external pure returns (uint256) {
        return MIN_ALLOCATION;
    }

    /// @inheritdoc IMandateEscrowV1
    function mandateSize() public view returns (uint256) {
        (uint256 outstanding, ) = IMandateRouter(ROUTER).sizeAndExposure(address(this), 0);
        return freeBalance() + outstanding;
    }

    /// @inheritdoc IMandateEscrowV1
    function projectLimit(uint256 pid)
        public
        view
        returns (uint256 cap, uint256 exposure, uint256 room)
    {
        uint256 outstanding;
        (outstanding, exposure) = IMandateRouter(ROUTER).sizeAndExposure(address(this), pid);
        cap = ((freeBalance() + outstanding) * _projectLimitBps) / BPS;
        room = cap > exposure ? cap - exposure : 0;
    }

    // ── owner ───────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateEscrowV1
    function depositWithAuthorization(
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata sig
    ) external {
        // Ungated on purpose: `from` and `to` are hardwired below and covered by the signature, so a
        // third party can only pick the moment and pay the gas. USDC's own `msg.sender == to` keeps
        // the authorization unusable elsewhere.
        address owner_ = owner;
        IERC3009(USDC).receiveWithAuthorization(
            owner_,
            address(this),
            value,
            validAfter,
            validBefore,
            nonce,
            sig
        );
        emit Deposited(owner_, value);
    }

    /// @inheritdoc IMandateEscrowV1
    function withdraw(address token, uint256 amount) external onlyOwner {
        _payOut(token, amount);
    }

    /// @inheritdoc IMandateEscrowV1
    function withdrawAll(address token) external onlyOwner {
        _payOut(token, IERC20(token).balanceOf(address(this)));
    }

    /// @dev No state gate and no signature: withdrawal must work while paused, and the recipient is
    ///      always recipientOf(owner), so a stolen key cannot redirect the money. The token is an
    ///      argument so anything landing here can leave — an immutable clone cannot gain a rescue
    ///      function later.
    function _payOut(address token, uint256 amount) private {
        address to = _recipient();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(to, token, amount);
    }

    function pause() external onlyOwner {
        state = MandateState.PAUSED_BY_OWNER;
        emit StateChanged(MandateState.PAUSED_BY_OWNER);
    }

    function resume() external onlyOwner {
        state = MandateState.ACTIVE;
        emit StateChanged(MandateState.ACTIVE);
    }

    // ── anyone, once the owner is flagged compromised ───────────────────────────

    /// @inheritdoc IMandateEscrowV1
    function sweepToClaimAddress() external {
        address owner_ = owner;
        IManagerRegistry registry = IManagerRegistry(MANAGER_REGISTRY);

        // The only gate, and a revert rather than a soft condition: without it anyone could empty a
        // healthy mandate onto its owner's wallet, which stops it re-placing.
        if (!registry.isCompromised(owner_)) revert NotCompromised();

        // Ungated beyond that: the caller picks nothing — destination and amount both come from
        // state — and this is the recovery path, where liveness matters more than a caller list that
        // excluded nobody with a motive.
        address to = registry.recipientOf(owner_);
        uint256 amount = freeBalance();
        if (amount == 0) revert NothingToSweep();

        IERC20(USDC).safeTransfer(to, amount);
        emit SweptToClaimAddress(to, amount);
    }

    // ── operator ────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateEscrowV1
    function allocate(uint256 pid, address inviter) external onlyOperator {
        if (state != MandateState.ACTIVE) revert NotActive();

        IFundraise.Project memory project = IFundraise(FUNDRAISE).projects(pid);
        if (project.innerStruct.stage != IFundraise.Stage.Open) revert ProjectNotOpen();

        (, uint256 exposure, uint256 room) = projectLimit(pid);

        // First entry only. On a top-up placing does not change mandateSize, so cap stays put and
        // room is zero from the second pass on — an unconditional floor would pour the whole balance
        // into one project ticket by ticket.
        uint256 want = (exposure == 0 && room < MIN_ALLOCATION) ? MIN_ALLOCATION : room;

        uint256 capacity = project.hardCap > project.totalInvested
            ? project.hardCap - project.totalInvested
            : 0;
        uint256 amount = Math.min(Math.min(want, capacity), freeBalance());
        if (amount < MIN_ALLOCATION) revert BelowMinimum(amount);

        address owner_ = owner;
        address routed = IMandateRouter(ROUTER).routes(owner_, pid);
        if (routed != address(0) && routed != address(this)) revert RoutedElsewhere(routed);
        // enrollSelf refuses a project the owner already holds manually: a mandate must not capture
        // manual shares on its own initiative. The owner lifts that with setRoute.
        if (routed == address(0)) IMandateRouter(ROUTER).enrollSelf(pid);

        IERC20(USDC).forceApprove(FUNDRAISE, amount);
        IMandateFundraise(FUNDRAISE).investFromMandate(owner_, pid, amount, inviter);
        IERC20(USDC).forceApprove(FUNDRAISE, 0);

        emit Allocated(pid, amount, paramsHash(), inviter);
    }

    // ── Fundraise only ──────────────────────────────────────────────────────────

    /// @inheritdoc IMandateEscrowV1
    function onPayout(
        uint256 pid,
        uint256 fresh,
        uint256 invested,
        uint256 claimed,
        uint256 rate,
        bytes32 marketId
    ) external {
        if (msg.sender != FUNDRAISE) revert NotFundraise();

        // Interest-first waterfall: a payout is interest up to whatever of the budget is unpaid.
        uint256 budget = (invested * rate) / BPS;
        uint256 was = claimed - fresh; // position in the waterfall before this payout
        uint256 interest = was >= budget ? 0 : Math.min(fresh, budget - was);

        emit PayoutSplit(pid, fresh - interest, interest);
        _forward(interest, marketId);
    }

    /// @dev Principal takes no part here: it is already on the balance and stays there, which is
    ///      what the next allocation places.
    function _forward(uint256 interest, bytes32 marketId) private {
        if (interest == 0) return; // LEND would revert on Lending8's exactlyOneZero

        InterestDirection direction = InterestDirection(_interestDirection);
        // principal and interest share one balance; the split is a no-op
        if (direction == InterestDirection.KEEP) return;

        address to;
        if (direction == InterestDirection.WALLET) {
            to = _recipient();
            IERC20(USDC).safeTransfer(to, interest);
        } else {
            if (marketId == bytes32(0)) revert ZeroMarketId();
            // Transfer target, not beneficiary: the position belongs to the owner via onBehalf.
            to = LENDING8;
            MarketParams memory marketParams = ILending8(LENDING8).idToMarketParams(Id.wrap(marketId));
            // A market that lends something else would make Lending8 pull a token this escrow does
            // not hold, failing somewhere inside it. One SLOAD buys a legible revert instead.
            if (marketParams.loanToken != USDC) revert MarketLoanTokenNotUsdc(marketParams.loanToken);
            IERC20(USDC).forceApprove(LENDING8, interest);
            ILending8(LENDING8).supply(marketParams, interest, 0, owner, "");
            IERC20(USDC).forceApprove(LENDING8, 0);
        }
        emit InterestForwarded(uint8(direction), interest, to);
    }

    // ── internals ───────────────────────────────────────────────────────────────

    /// @dev Every outgoing transfer goes through here, so a compromised owner's money follows the
    ///      registry's recovery address without this clone storing one.
    function _recipient() private view returns (address) {
        return IManagerRegistry(MANAGER_REGISTRY).recipientOf(owner);
    }
}
