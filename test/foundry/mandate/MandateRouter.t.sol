// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MandateRouter } from "../../../contracts/mandate/MandateRouter.sol";
import { IMandateRouter } from "../../../contracts/mandate/interfaces/IMandateRouter.sol";
import { IFundraise } from "../../../contracts/interfaces/protocol/IFundraise.sol";

/// @dev Answers isEscrowOf from a table the test fills, so the router's behaviour is exercised
///      without dragging the real derivation in — that one has its own suite.
contract FactoryStub {
    mapping(address => mapping(address => bool)) public owns;

    function set(address owner, address escrow) external {
        owns[owner][escrow] = true;
    }

    function isEscrowOf(address owner, address escrow) external view returns (bool) {
        return owns[owner][escrow];
    }
}

contract RegistryStub {
    address public mandateFactory;
    mapping(address => bool) public operators;

    function setFactory(address f) external { mandateFactory = f; }
    function setOperator(address a, bool v) external { operators[a] = v; }
    function isOperator(address a) external view returns (bool) { return operators[a]; }
}

contract FundraiseStub {
    mapping(address => mapping(uint256 => IFundraise.InvestorInfo)) private _info;
    mapping(uint256 => IFundraise.Stage) private _stage;

    function setInfo(address who, uint256 pid, uint256 invested, uint256 claimed) external {
        _info[who][pid] = IFundraise.InvestorInfo({ investedAmount: invested, totalClaimed: claimed });
    }

    function setStage(uint256 pid, IFundraise.Stage s) external { _stage[pid] = s; }

    function investorInfo(address who, uint256 pid) external view returns (IFundraise.InvestorInfo memory) {
        return _info[who][pid];
    }

    function projects(uint256 pid) external view returns (IFundraise.Project memory p) {
        p.innerStruct.stage = _stage[pid];
    }
}

/// @dev Stands in for an escrow: the router only ever asks it who owns it.
contract EscrowStub {
    address public owner;
    constructor(address o) { owner = o; }

    function enroll(MandateRouter router, uint256 pid) external {
        router.enrollSelf(pid);
    }
}

contract MandateRouterTest is Test {
    MandateRouter router;
    FactoryStub factory;
    RegistryStub registry;
    FundraiseStub fundraise;
    EscrowStub escrow;
    EscrowStub otherEscrow;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address operator = address(0x00E7A);

    uint256 constant PID = 7;

    function setUp() public {
        factory = new FactoryStub();
        registry = new RegistryStub();
        fundraise = new FundraiseStub();
        registry.setFactory(address(factory));
        registry.setOperator(operator, true);

        router = MandateRouter(address(new ERC1967Proxy(
            address(new MandateRouter()),
            abi.encodeCall(MandateRouter.initialize, (address(this), address(registry), address(fundraise)))
        )));

        escrow = new EscrowStub(alice);
        otherEscrow = new EscrowStub(alice);
        factory.set(alice, address(escrow));
        factory.set(alice, address(otherEscrow));
    }

    // ── setRoute ────────────────────────────────────────────────────────────────

    function test_owner_routes_a_project_to_their_escrow() public {
        vm.expectEmit(true, true, false, true, address(router));
        emit IMandateRouter.RouteSet(alice, PID, address(escrow), address(0));
        vm.prank(alice);
        router.setRoute(PID, address(escrow));

        assertEq(router.routes(alice, PID), address(escrow));
        assertEq(router.enrolledPids(address(escrow)).length, 1);
    }

    /// Routing an address that is not the caller's escrow is the one check setRoute makes.
    function test_setRoute_rejects_someone_elses_escrow() public {
        vm.expectRevert(
            abi.encodeWithSelector(MandateRouter.NotAnEscrowOf.selector, bob, address(escrow))
        );
        vm.prank(bob);
        router.setRoute(PID, address(escrow));
    }

    /// The factory address lives in the registry, so a zero there stops enrolment entirely.
    function test_setRoute_reverts_while_the_registry_has_no_factory() public {
        registry.setFactory(address(0));
        vm.expectRevert(MandateRouter.NoMandateFactory.selector);
        vm.prank(alice);
        router.setRoute(PID, address(escrow));
    }

    /// Moving a project between an owner's own mandates keeps one route and one list entry.
    function test_moving_a_route_leaves_the_old_escrow() public {
        vm.startPrank(alice);
        router.setRoute(PID, address(escrow));

        vm.expectEmit(true, true, false, true, address(router));
        emit IMandateRouter.RouteSet(alice, PID, address(otherEscrow), address(escrow));
        router.setRoute(PID, address(otherEscrow));
        vm.stopPrank();

        assertEq(router.routes(alice, PID), address(otherEscrow));
        assertEq(router.enrolledPids(address(escrow)).length, 0);
        assertEq(router.enrolledPids(address(otherEscrow)).length, 1);
    }

    /// Manual positions are no obstacle: the whole project moves, holdings and all.
    function test_setRoute_works_on_a_project_the_owner_already_holds() public {
        fundraise.setInfo(alice, PID, 500e6, 0);
        vm.prank(alice);
        router.setRoute(PID, address(escrow));
        assertEq(router.routes(alice, PID), address(escrow));
    }

    // ── setRouteMany ────────────────────────────────────────────────────────────

    function test_setRouteMany_is_all_or_nothing() public {
        uint256[] memory pids = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) pids[i] = i + 1;

        // The escrow is not bob's, so the single ownership check fails and nothing lands.
        vm.expectRevert(
            abi.encodeWithSelector(MandateRouter.NotAnEscrowOf.selector, bob, address(escrow))
        );
        vm.prank(bob);
        router.setRouteMany(pids, address(escrow));

        for (uint256 i = 0; i < 10; i++) assertEq(router.routes(bob, pids[i]), address(0));
        assertEq(router.enrolledPids(address(escrow)).length, 0);
    }

    // ── detach ──────────────────────────────────────────────────────────────────

    /// One of the actions by which a user takes control back — no signature, any mandate state.
    function test_detach_needs_nothing_but_an_existing_route() public {
        vm.startPrank(alice);
        router.setRoute(PID, address(escrow));

        vm.expectEmit(true, true, false, true, address(router));
        emit IMandateRouter.RouteSet(alice, PID, address(0), address(escrow));
        router.detach(PID);
        vm.stopPrank();

        assertEq(router.routes(alice, PID), address(0));
        assertEq(router.enrolledPids(address(escrow)).length, 0);
    }

    /// And it can be undone without conditions, which is what makes detaching safe to use.
    function test_a_detached_project_can_be_routed_back() public {
        vm.startPrank(alice);
        router.setRoute(PID, address(escrow));
        router.detach(PID);
        router.setRoute(PID, address(escrow));
        vm.stopPrank();

        assertEq(router.routes(alice, PID), address(escrow));
        assertEq(router.enrolledPids(address(escrow)).length, 1, "no duplicate list entry");
    }

    function test_detach_reverts_without_a_route() public {
        vm.expectRevert(abi.encodeWithSelector(MandateRouter.NoRoute.selector, PID));
        vm.prank(alice);
        router.detach(PID);
    }

    // ── enrollSelf ──────────────────────────────────────────────────────────────

    function test_enrollSelf_routes_the_project_to_the_calling_escrow() public {
        escrow.enroll(router, PID);
        assertEq(router.routes(alice, PID), address(escrow));
    }

    /// A mandate must not capture manual shares on its own initiative — the owner lifts that with
    /// setRoute, which is exactly the asymmetry the rule is about.
    function test_enrollSelf_refuses_a_project_the_owner_already_holds() public {
        fundraise.setInfo(alice, PID, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(MandateRouter.AlreadyInvested.selector, PID));
        escrow.enroll(router, PID);

        vm.prank(alice);
        router.setRoute(PID, address(escrow));
        assertEq(router.routes(alice, PID), address(escrow), "the owner may hand it over");
    }

    /// The same gate as setRoute: enrolment on the mandate's own initiative stops too.
    function test_enrollSelf_reverts_while_the_registry_has_no_factory() public {
        registry.setFactory(address(0));
        vm.expectRevert(MandateRouter.NoMandateFactory.selector);
        escrow.enroll(router, PID);
    }

    function test_enrollSelf_rejects_a_caller_the_factory_disowns() public {
        EscrowStub impostor = new EscrowStub(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MandateRouter.NotAnEscrowOf.selector, alice, address(impostor))
        );
        impostor.enroll(router, PID);
    }

    // ── sizeAndExposure ─────────────────────────────────────────────────────────

    /// Outstanding principal, summed over enrolled projects, with one project singled out.
    function test_sizeAndExposure_sums_outstanding_principal() public {
        fundraise.setInfo(alice, 1, 1_000e6, 400e6);   // 600 left
        fundraise.setInfo(alice, 2, 500e6, 0);         // 500 left
        fundraise.setInfo(alice, 3, 300e6, 900e6);     // repaid with interest → 0, not negative

        uint256[] memory pids = new uint256[](3);
        pids[0] = 1; pids[1] = 2; pids[2] = 3;
        vm.prank(alice);
        router.setRouteMany(pids, address(escrow));

        (uint256 outstanding, uint256 exposure) = router.sizeAndExposure(address(escrow), 2);
        assertEq(outstanding, 1_100e6);
        assertEq(exposure, 500e6);

        (, uint256 none) = router.sizeAndExposure(address(escrow), 99);
        assertEq(none, 0, "a project outside the list has no exposure");
    }

    // ── clearIfEmpty ────────────────────────────────────────────────────────────

    function test_clearIfEmpty_removes_a_settled_project() public {
        fundraise.setInfo(alice, PID, 1_000e6, 1_200e6);
        fundraise.setStage(PID, IFundraise.Stage.Repaid);
        vm.prank(alice);
        router.setRoute(PID, address(escrow));

        vm.prank(operator);
        router.clearIfEmpty(alice, PID);

        assertEq(router.routes(alice, PID), address(0));
        assertEq(router.enrolledPids(address(escrow)).length, 0);
    }

    function test_clearIfEmpty_keeps_a_project_with_principal_left() public {
        fundraise.setInfo(alice, PID, 1_000e6, 400e6);
        fundraise.setStage(PID, IFundraise.Stage.Repaid);
        vm.prank(alice);
        router.setRoute(PID, address(escrow));

        vm.expectRevert(
            abi.encodeWithSelector(MandateRouter.StillOutstanding.selector, PID, uint256(600e6))
        );
        vm.prank(operator);
        router.clearIfEmpty(alice, PID);
    }

    /// Zero outstanding is not enough on its own: a position listed on the market reads the same,
    /// and clearing then would bring the lots back unrouted.
    function test_clearIfEmpty_keeps_a_project_that_is_still_running() public {
        fundraise.setStage(PID, IFundraise.Stage.Funded);
        vm.prank(alice);
        router.setRoute(PID, address(escrow));

        vm.expectRevert(abi.encodeWithSelector(MandateRouter.ProjectNotSettled.selector, PID));
        vm.prank(operator);
        router.clearIfEmpty(alice, PID);
    }

    function test_clearIfEmpty_is_operator_only() public {
        fundraise.setStage(PID, IFundraise.Stage.Repaid);
        vm.prank(alice);
        router.setRoute(PID, address(escrow));

        vm.expectRevert(MandateRouter.NotOperator.selector);
        vm.prank(alice);
        router.clearIfEmpty(alice, PID);
    }

    function test_clearIfEmptyMany_clears_a_batch() public {
        uint256[] memory pids = new uint256[](2);
        pids[0] = 1; pids[1] = 2;
        address[] memory owners = new address[](2);
        owners[0] = alice; owners[1] = alice;

        fundraise.setStage(1, IFundraise.Stage.Repaid);
        fundraise.setStage(2, IFundraise.Stage.Canceled);
        vm.prank(alice);
        router.setRouteMany(pids, address(escrow));

        vm.prank(operator);
        router.clearIfEmptyMany(owners, pids);
        assertEq(router.enrolledPids(address(escrow)).length, 0);
    }
}
