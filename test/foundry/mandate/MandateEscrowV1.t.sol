// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MandateEscrowV1 } from "../../../contracts/mandate/MandateEscrowV1.sol";
import { IMandateEscrowV1 } from "../../../contracts/mandate/interfaces/IMandateEscrowV1.sol";
import { ImmutableParamsV1, MandateState } from "../../../contracts/mandate/interfaces/MandateTypes.sol";
import { IFundraise } from "../../../contracts/interfaces/protocol/IFundraise.sol";
import { Id, MarketParams } from "../../../contracts/lending/interfaces/ILending8.sol";
import { MockUSDC3009 } from "../mocks/MockUSDC3009.sol";

/// @dev Stands in for ManagerRegistry: only the three predicates the escrow reads.
contract RegistryStub {
    mapping(address => bool) public operators;
    mapping(address => address) public recovery;

    function setOperator(address a, bool v) external { operators[a] = v; }
    function setRecovery(address user, address to) external { recovery[user] = to; }

    function isOperator(address a) external view returns (bool) { return operators[a]; }
    function recipientOf(address u) external view returns (address) {
        address to = recovery[u];
        return to == address(0) ? u : to;
    }
    function isCompromised(address u) external view returns (bool) {
        return recovery[u] != address(0) && recovery[u] != u;
    }
    function mandateFactory() external pure returns (address) { return address(0); }
}

/// @dev Stands in for MandateRouter. `outstanding` and `exposure` are set by the test so the
///      allocation formula can be driven directly, which is the point of these cases.
contract RouterStub {
    mapping(address => mapping(uint256 => address)) public routes;
    uint256 public outstanding;
    mapping(uint256 => uint256) public exposureOf;
    uint256 public enrollCalls;
    bool public enrollReverts;

    function setRoute(address owner, uint256 pid, address escrow) external { routes[owner][pid] = escrow; }
    function setOutstanding(uint256 v) external { outstanding = v; }
    function setExposure(uint256 pid, uint256 v) external { exposureOf[pid] = v; }
    function setEnrollReverts(bool v) external { enrollReverts = v; }

    function sizeAndExposure(address, uint256 targetPid) external view returns (uint256, uint256) {
        return (outstanding, exposureOf[targetPid]);
    }

    function enrollSelf(uint256) external {
        require(!enrollReverts, "owner already holds this project");
        enrollCalls++;
    }
}

/// @dev Stands in for Fundraise: one project and a recording investFromMandate.
contract FundraiseStub {
    IFundraise.Project internal project;
    address public lastOwner;
    uint256 public lastAmount;
    address public lastInviter;
    uint256 public calls;
    IERC20 internal usdc;

    constructor(IERC20 usdc_) { usdc = usdc_; }

    function setProject(uint256 hardCap, uint256 totalInvested, IFundraise.Stage stage) external {
        project.hardCap = hardCap;
        project.totalInvested = totalInvested;
        project.innerStruct.stage = stage;
    }

    function projects(uint256) external view returns (IFundraise.Project memory) { return project; }

    function investFromMandate(address owner, uint256, uint256 amount, address inviter) external {
        lastOwner = owner;
        lastAmount = amount;
        lastInviter = inviter;
        calls++;
        usdc.transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev Stands in for Lending8: records what `supply` was called with, and answers
///      `idToMarketParams` so the escrow can build the struct it forwards.
/// @dev Covers our side of the call only. The stub echoes whatever params were put into it, so a
///      mismatch between the `marketId` we are handed and what Lending8 really stores under it would
///      pass here — worth an integration test against a real Lending8 when the interest direction is
///      built out. Foundry is the likely fit (`test/lending/lending8.test.ts` forks nothing), but
///      that scaffolding already exists; decide closer to the time.
contract Lending8Stub {
    mapping(bytes32 => MarketParams) private _params;

    address public lastOnBehalf;
    uint256 public lastAssets;
    uint256 public lastShares;
    address public lastLoanToken;
    uint256 public supplyCalls;

    function setMarket(bytes32 id, MarketParams memory p) external {
        _params[id] = p;
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _params[Id.unwrap(id)];
    }

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory
    ) external returns (uint256, uint256) {
        lastLoanToken = marketParams.loanToken;
        lastAssets = assets;
        lastShares = shares;
        lastOnBehalf = onBehalf;
        supplyCalls++;
        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, 0);
    }
}

contract MandateEscrowV1Test is Test {
    uint256 constant MIN = 100e6;
    uint256 constant PID = 7;

    MockUSDC3009 usdc;
    RegistryStub registry;
    RouterStub router;
    FundraiseStub fundraise;
    Lending8Stub lending;
    MandateEscrowV1 impl;
    MandateEscrowV1 escrow;

    uint256 ownerKey = 0xA11CE;
    address owner;
    address operator = address(0x00E7A);

    function setUp() public {
        owner = vm.addr(ownerKey);
        usdc = new MockUSDC3009();
        registry = new RegistryStub();
        router = new RouterStub();
        fundraise = new FundraiseStub(IERC20(address(usdc)));
        lending = new Lending8Stub();

        impl = new MandateEscrowV1(
            address(usdc), address(fundraise), address(registry), address(router), address(lending)
        );
        escrow = MandateEscrowV1(Clones.clone(address(impl)));
        escrow.initialize(owner, ImmutableParamsV1({ interestDirection: 0, projectLimitBps: 1000 }));

        registry.setOperator(operator, true);
        fundraise.setProject(1_000_000e6, 0, IFundraise.Stage.Open);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(address(escrow), amount);
    }

    // ── parameter bounds ────────────────────────────────────────────────────────

    function test_initialize_rejects_direction_above_two() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(MandateEscrowV1.BadInterestDirection.selector, uint8(3)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 3, projectLimitBps: 1000 }));
    }

    function test_initialize_rejects_zero_and_over_full_bps() public {
        MandateEscrowV1 a = MandateEscrowV1(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(MandateEscrowV1.BadProjectLimitBps.selector, uint16(0)));
        a.initialize(owner, ImmutableParamsV1({ interestDirection: 0, projectLimitBps: 0 }));

        MandateEscrowV1 b = MandateEscrowV1(Clones.clone(address(impl)));
        vm.expectRevert(abi.encodeWithSelector(MandateEscrowV1.BadProjectLimitBps.selector, uint16(10001)));
        b.initialize(owner, ImmutableParamsV1({ interestDirection: 0, projectLimitBps: 10001 }));
    }

    function test_initialize_is_once_only() public {
        vm.expectRevert(MandateEscrowV1.AlreadyInitialized.selector);
        escrow.initialize(owner, ImmutableParamsV1({ interestDirection: 1, projectLimitBps: 500 }));
    }

    function test_params_are_readable_and_hash_matches_encoding() public view {
        ImmutableParamsV1 memory p = escrow.params();
        assertEq(p.interestDirection, 0);
        assertEq(p.projectLimitBps, 1000);
        assertEq(escrow.paramsHash(), keccak256(abi.encode(p)), "hash must match the factory's encoding");
        assertEq(escrow.version(), 1);
        assertEq(escrow.minAllocation(), MIN);
    }

    function test_no_rule_setter_exists() public {
        // If a setter is ever added, this call stops reverting and the test fails loudly.
        (bool ok, ) = address(escrow).call(abi.encodeWithSignature("setProjectLimitBps(uint16)", uint16(5000)));
        assertFalse(ok, "mandate rules must have no setter");
    }

    // ── the allocation formula ──────────────────────────────────────────────────

    function test_first_entry_below_minimum_places_the_minimum() public {
        // 10% of 500 USDC is 50 — under the floor, so the floor is placed instead.
        _fund(500e6);
        vm.prank(operator);
        escrow.allocate(PID, address(0));
        assertEq(fundraise.lastAmount(), MIN, "first entry must be raised to the floor");
    }

    function test_top_up_below_minimum_reverts() public {
        _fund(500e6);
        vm.prank(operator);
        escrow.allocate(PID, address(0));

        // Second pass: exposure is non-zero, so the floor no longer applies and room is what is
        // left of the cap — here nothing.
        router.setExposure(PID, MIN);
        router.setOutstanding(MIN);
        vm.expectRevert(abi.encodeWithSelector(MandateEscrowV1.BelowMinimum.selector, uint256(0)));
        vm.prank(operator);
        escrow.allocate(PID, address(0));
    }

    function test_limit_subtracts_existing_exposure() public {
        // size = free 9000 + outstanding 1000 = 10000; cap at 10% = 1000; exposure 400 leaves 600.
        _fund(9_000e6);
        router.setOutstanding(1_000e6);
        router.setExposure(PID, 400e6);

        (uint256 cap, uint256 exposure, uint256 room) = escrow.projectLimit(PID);
        assertEq(cap, 1_000e6);
        assertEq(exposure, 400e6);
        assertEq(room, 600e6);

        vm.prank(operator);
        escrow.allocate(PID, address(0));
        assertEq(fundraise.lastAmount(), 600e6, "placement is capped by the remaining room");
    }

    function test_amount_is_capped_by_project_capacity_and_free_balance() public {
        _fund(50_000e6);
        router.setOutstanding(0);
        fundraise.setProject(1_000e6, 700e6, IFundraise.Stage.Open); // 300 of capacity left
        vm.prank(operator);
        escrow.allocate(PID, address(0));
        assertEq(fundraise.lastAmount(), 300e6, "project capacity binds");

        // Now make the free balance the binding constraint.
        MandateEscrowV1 small = MandateEscrowV1(Clones.clone(address(impl)));
        small.initialize(owner, ImmutableParamsV1({ interestDirection: 0, projectLimitBps: 10000 }));
        usdc.mint(address(small), 150e6);
        fundraise.setProject(1_000_000e6, 0, IFundraise.Stage.Open);
        vm.prank(operator);
        small.allocate(PID, address(0));
        assertEq(fundraise.lastAmount(), 150e6, "free balance binds");
    }

    function test_allocate_passes_owner_and_inviter_through() public {
        _fund(5_000e6);
        vm.prank(operator);
        escrow.allocate(PID, address(0xBEEF));
        assertEq(fundraise.lastOwner(), owner, "investor recorded is the owner, not the escrow");
        assertEq(fundraise.lastInviter(), address(0xBEEF));
        assertEq(usdc.allowance(address(escrow), address(fundraise)), 0, "allowance must be reset");
    }

    function test_allocate_requires_operator() public {
        _fund(5_000e6);
        vm.expectRevert(MandateEscrowV1.NotOperator.selector);
        vm.prank(owner);
        escrow.allocate(PID, address(0));
    }

    function test_allocate_requires_open_stage() public {
        _fund(5_000e6);
        fundraise.setProject(1_000_000e6, 0, IFundraise.Stage.Funded);
        vm.expectRevert(MandateEscrowV1.ProjectNotOpen.selector);
        vm.prank(operator);
        escrow.allocate(PID, address(0));
    }

    function test_allocate_refuses_project_routed_to_another_escrow() public {
        _fund(5_000e6);
        router.setRoute(owner, PID, address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(MandateEscrowV1.RoutedElsewhere.selector, address(0xDEAD)));
        vm.prank(operator);
        escrow.allocate(PID, address(0));
    }

    function test_allocate_enrolls_once_then_reuses_the_route() public {
        _fund(50_000e6);
        vm.prank(operator);
        escrow.allocate(PID, address(0));
        assertEq(router.enrollCalls(), 1);

        router.setRoute(owner, PID, address(escrow));
        router.setExposure(PID, 100e6);
        vm.prank(operator);
        escrow.allocate(PID, address(0));
        assertEq(router.enrollCalls(), 1, "an already routed project must not be enrolled again");
    }

    function test_allocate_blocked_while_paused() public {
        _fund(5_000e6);
        vm.prank(owner);
        escrow.pause();
        assertEq(uint8(escrow.state()), uint8(MandateState.PAUSED_BY_OWNER));

        vm.expectRevert(MandateEscrowV1.NotActive.selector);
        vm.prank(operator);
        escrow.allocate(PID, address(0));

        vm.prank(owner);
        escrow.resume();
        vm.prank(operator);
        escrow.allocate(PID, address(0));
        assertEq(fundraise.calls(), 1);
    }

    // ── withdrawal ──────────────────────────────────────────────────────────────

    function test_withdraw_works_while_paused_without_signature() public {
        _fund(1_000e6);
        vm.prank(owner);
        escrow.pause();

        vm.prank(owner);
        escrow.withdraw(address(usdc), 400e6);
        assertEq(usdc.balanceOf(owner), 400e6);

        vm.prank(owner);
        escrow.withdrawAll(address(usdc));
        assertEq(usdc.balanceOf(owner), 1_000e6);
        assertEq(escrow.freeBalance(), 0);
    }

    function test_withdraw_goes_to_the_recovery_address_when_compromised() public {
        _fund(1_000e6);
        address recovery = address(0xB0B);
        registry.setRecovery(owner, recovery);

        vm.prank(owner);
        escrow.withdrawAll(address(usdc));
        assertEq(usdc.balanceOf(recovery), 1_000e6, "a stolen key cannot redirect the money");
        assertEq(usdc.balanceOf(owner), 0);
    }

    function test_withdraw_is_owner_only() public {
        _fund(1_000e6);
        vm.expectRevert(MandateEscrowV1.NotOwner.selector);
        vm.prank(operator);
        escrow.withdraw(address(usdc), 1);
    }

    // ── sweep ───────────────────────────────────────────────────────────────────

    function test_sweep_requires_compromised_flag() public {
        _fund(1_000e6);
        vm.expectRevert(MandateEscrowV1.NotCompromised.selector);
        vm.prank(owner);
        escrow.sweepToClaimAddress();
    }

    /// Anyone may call it — the caller picks neither the recipient nor the amount, and on the
    /// recovery path a live third party is worth more than a caller list.
    function test_sweep_is_callable_by_anyone_and_always_pays_the_recovery_address() public {
        address recovery = address(0xB0B);
        registry.setRecovery(owner, recovery);

        _fund(300e6);
        vm.prank(address(0xBAD));
        escrow.sweepToClaimAddress();
        assertEq(usdc.balanceOf(recovery), 300e6, "a stranger cannot redirect it");
        assertEq(usdc.balanceOf(address(0xBAD)), 0);

        _fund(200e6);
        vm.prank(operator);
        escrow.sweepToClaimAddress();
        assertEq(usdc.balanceOf(recovery), 500e6, "recipient is the recovery address whoever calls");
    }

    // ── payout waterfall ────────────────────────────────────────────────────────

    function test_onPayout_is_fundraise_only() public {
        vm.expectRevert(MandateEscrowV1.NotFundraise.selector);
        escrow.onPayout(PID, 1, 1, 1, 0, bytes32(0));
    }

    /// @dev Interest budget = invested * rate / 10000. Interest is paid first, so a payout is
    ///      interest until the budget is exhausted, then principal.
    function test_waterfall_pays_interest_first_then_principal() public {
        uint256 invested = 1_000e6;
        uint256 rate = 1_500; // 15% → budget 150

        // First payout of 100: entirely interest.
        vm.expectEmit(true, false, false, true, address(escrow));
        emit IMandateEscrowV1.PayoutSplit(PID, 0, 100e6);
        vm.prank(address(fundraise));
        escrow.onPayout(PID, 100e6, invested, 100e6, rate, bytes32(0));

        // Second payout of 100 with 100 already claimed: 50 finishes the budget, 50 is principal.
        vm.expectEmit(true, false, false, true, address(escrow));
        emit IMandateEscrowV1.PayoutSplit(PID, 50e6, 50e6);
        vm.prank(address(fundraise));
        escrow.onPayout(PID, 100e6, invested, 200e6, rate, bytes32(0));

        // Third payout: budget spent, all principal.
        vm.expectEmit(true, false, false, true, address(escrow));
        emit IMandateEscrowV1.PayoutSplit(PID, 100e6, 0);
        vm.prank(address(fundraise));
        escrow.onPayout(PID, 100e6, invested, 300e6, rate, bytes32(0));
    }

    function test_direction_zero_keeps_interest_on_the_balance() public {
        _fund(500e6);
        vm.prank(address(fundraise));
        escrow.onPayout(PID, 100e6, 1_000e6, 100e6, 1_500, bytes32(0));
        assertEq(escrow.freeBalance(), 500e6, "nothing leaves under direction 0");
    }

    function test_direction_one_forwards_interest_to_the_recipient() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 1, projectLimitBps: 1000 }));
        usdc.mint(address(e), 100e6);

        vm.prank(address(fundraise));
        e.onPayout(PID, 100e6, 1_000e6, 100e6, 1_500, bytes32(0));
        assertEq(usdc.balanceOf(owner), 100e6, "interest goes out, principal would stay");
        assertEq(e.freeBalance(), 0);
    }

    function test_direction_two_rejects_a_zero_market_id() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 2, projectLimitBps: 1000 }));
        usdc.mint(address(e), 100e6);

        vm.expectRevert(MandateEscrowV1.ZeroMarketId.selector);
        vm.prank(address(fundraise));
        e.onPayout(PID, 100e6, 1_000e6, 100e6, 1_500, bytes32(0));
    }

    /// Happy path of direction 2 — previously only its revert branches were covered.
    function test_direction_two_supplies_interest_into_lending() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 2, projectLimitBps: 1000 }));
        usdc.mint(address(e), 300e6);

        bytes32 marketId = keccak256("USDC/BTC8L");
        lending.setMarket(marketId, MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xB7C8),
            irm: address(0x121212),
            lltv: 0.8e18
        }));

        vm.expectEmit(false, false, false, true, address(e));
        emit IMandateEscrowV1.InterestForwarded(2, 100e6, address(lending));
        vm.prank(address(fundraise));
        e.onPayout(PID, 100e6, 1_000e6, 100e6, 1_500, marketId);

        assertEq(lending.supplyCalls(), 1);
        assertEq(lending.lastAssets(), 100e6, "interest only");
        assertEq(lending.lastShares(), 0, "assets branch of exactlyOneZero");
        assertEq(lending.lastOnBehalf(), owner, "position belongs to the owner, not the escrow");
        assertEq(lending.lastLoanToken(), address(usdc), "market params come from idToMarketParams");
        assertEq(e.freeBalance(), 200e6, "principal stays on the balance");
    }

    /// A market lending something other than USDC would make Lending8 pull a token the escrow does
    /// not hold; the check turns that into a legible revert instead of a failure inside Lending8.
    function test_direction_two_rejects_a_market_that_does_not_lend_usdc() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 2, projectLimitBps: 1000 }));
        usdc.mint(address(e), 100e6);

        bytes32 marketId = keccak256("WETH/BTC8L");
        address weth = address(0x4200);
        lending.setMarket(marketId, MarketParams({
            loanToken: weth,
            collateralToken: address(0xB7C8),
            irm: address(0x121212),
            lltv: 0.8e18
        }));

        vm.expectRevert(
            abi.encodeWithSelector(MandateEscrowV1.MarketLoanTokenNotUsdc.selector, weth)
        );
        vm.prank(address(fundraise));
        e.onPayout(PID, 100e6, 1_000e6, 100e6, 1_500, marketId);
    }

    /// The allowance is opened and closed inside the same call, so nothing is left standing.
    function test_direction_two_leaves_no_allowance_behind() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 2, projectLimitBps: 1000 }));
        usdc.mint(address(e), 100e6);

        bytes32 marketId = keccak256("USDC/BTC8L");
        lending.setMarket(marketId, MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xB7C8),
            irm: address(0x121212),
            lltv: 0.8e18
        }));

        vm.prank(address(fundraise));
        e.onPayout(PID, 100e6, 1_000e6, 100e6, 1_500, marketId);
        assertEq(usdc.allowance(address(e), address(lending)), 0);
    }

    // ── deposit by authorization ────────────────────────────────────────────────

    function _signReceive(uint256 value, bytes32 nonce, uint256 validAfter, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = usdc.receiveDigest(owner, address(escrow), value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Pins the mock against the deployed FiatTokenV2_2: an encoding drift shows up here and
    ///      not on a testnet, where it would surface as an unexplained `invalid signature`.
    function test_typehash_matches_usdc() public view {
        assertEq(
            usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8
        );
    }

    /// Anyone may submit it — `from` and `to` are hardwired and covered by the signature, so a third
    /// party only chooses the moment and pays the gas.
    function test_deposit_by_authorization_can_be_submitted_by_anyone() public {
        usdc.mint(owner, 500e6);
        bytes32 nonce = keccak256("deposit-1");
        bytes memory sig = _signReceive(500e6, nonce, 0, block.timestamp + 1 hours);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit IMandateEscrowV1.Deposited(owner, 500e6);
        vm.prank(address(0xBEEF));
        escrow.depositWithAuthorization(500e6, 0, block.timestamp + 1 hours, nonce, sig);

        assertEq(escrow.freeBalance(), 500e6);
        assertEq(usdc.balanceOf(owner), 0);
        assertTrue(usdc.authorizationState(owner, nonce), "nonce is consumed");
    }

    /// Why this variant and not `transferWithAuthorization`: the token refuses the authorization to
    /// anyone but the payee.
    function test_authorization_cannot_be_spent_outside_the_escrow() public {
        usdc.mint(owner, 500e6);
        bytes32 nonce = keccak256("deposit-1");
        bytes memory sig = _signReceive(500e6, nonce, 0, block.timestamp + 1 hours);

        vm.expectRevert("FiatTokenV2: caller must be the payee");
        vm.prank(address(0xBEEF));
        usdc.receiveWithAuthorization(
            owner, address(escrow), 500e6, 0, block.timestamp + 1 hours, nonce, sig
        );
    }

    function test_deposit_authorization_is_one_shot() public {
        usdc.mint(owner, 1_000e6);
        bytes32 nonce = keccak256("deposit-1");
        bytes memory sig = _signReceive(500e6, nonce, 0, block.timestamp + 1 hours);

        escrow.depositWithAuthorization(500e6, 0, block.timestamp + 1 hours, nonce, sig);

        vm.expectRevert("FiatTokenV2: authorization is used or canceled");
        escrow.depositWithAuthorization(500e6, 0, block.timestamp + 1 hours, nonce, sig);
    }

    function test_deposit_respects_the_validity_window() public {
        usdc.mint(owner, 1_000e6);
        vm.warp(1_000);

        bytes32 early = keccak256("early");
        bytes memory sigEarly = _signReceive(100e6, early, block.timestamp + 100, block.timestamp + 200);
        vm.expectRevert("FiatTokenV2: authorization is not yet valid");
        escrow.depositWithAuthorization(100e6, block.timestamp + 100, block.timestamp + 200, early, sigEarly);

        bytes32 late = keccak256("late");
        bytes memory sigLate = _signReceive(100e6, late, 0, block.timestamp);
        vm.expectRevert("FiatTokenV2: authorization is expired");
        escrow.depositWithAuthorization(100e6, 0, block.timestamp, late, sigLate);
    }

    /// The signature covers the amount, so a submitter cannot pull more than was authorized.
    function test_deposit_rejects_a_tampered_amount() public {
        usdc.mint(owner, 1_000e6);
        bytes32 nonce = keccak256("deposit-1");
        bytes memory sig = _signReceive(100e6, nonce, 0, block.timestamp + 1 hours);

        vm.expectRevert("FiatTokenV2: invalid signature");
        escrow.depositWithAuthorization(900e6, 0, block.timestamp + 1 hours, nonce, sig);
    }

    /// An authorization signed for one escrow must not fund another: `to` is in the signed struct.
    function test_deposit_rejects_an_authorization_signed_for_another_escrow() public {
        usdc.mint(owner, 1_000e6);
        MandateEscrowV1 other = MandateEscrowV1(Clones.clone(address(impl)));
        other.initialize(owner, ImmutableParamsV1({ interestDirection: 0, projectLimitBps: 1000 }));

        bytes32 nonce = keccak256("deposit-1");
        bytes memory sig = _signReceive(100e6, nonce, 0, block.timestamp + 1 hours); // signed for `escrow`

        vm.expectRevert("FiatTokenV2: invalid signature");
        other.depositWithAuthorization(100e6, 0, block.timestamp + 1 hours, nonce, sig);
    }

    function test_zero_interest_forwards_nothing_under_any_direction() public {
        MandateEscrowV1 e = MandateEscrowV1(Clones.clone(address(impl)));
        e.initialize(owner, ImmutableParamsV1({ interestDirection: 2, projectLimitBps: 1000 }));
        usdc.mint(address(e), 100e6);

        // Budget already exhausted, so the whole payout is principal — the lending branch, which
        // would revert on the zero market id, must not be reached at all.
        vm.prank(address(fundraise));
        e.onPayout(PID, 100e6, 1_000e6, 5_000e6, 1_500, bytes32(0));
        assertEq(e.freeBalance(), 100e6);
    }
}
