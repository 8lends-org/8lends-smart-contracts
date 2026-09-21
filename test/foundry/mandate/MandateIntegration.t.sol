// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Market } from "../../../contracts/core/market/Market.sol";
import { MandateEscrowV1 } from "../../../contracts/mandate/MandateEscrowV1.sol";
import { MandateFactory } from "../../../contracts/mandate/MandateFactory.sol";
import { MandateRouter } from "../../../contracts/mandate/MandateRouter.sol";
import { IMandateEscrowV1 } from "../../../contracts/mandate/interfaces/IMandateEscrowV1.sol";
import { ImmutableParamsV1, InterestDirection } from "../../../contracts/mandate/interfaces/MandateTypes.sol";
import { Id, MarketParams } from "../../../contracts/lending/interfaces/ILending8.sol";

/// @dev Only there because the escrow's constructor refuses a zero address; the LEND direction is
///      not exercised here.
contract Lending8Placeholder {
    function idToMarketParams(Id) external pure returns (MarketParams memory p) {
        return p;
    }
}

/// @notice The mandate against the real Fundraise, Market, router and factory rather than stubs.
/// @dev Every other mandate suite runs on stubs, so nothing else proves the two sides agree. The
///      split in particular is computed by the escrow from numbers Fundraise keeps, and a position
///      moving through the secondary market rewrites both of them.
contract MandateIntegrationTest is Setup {
    MandateFactory factory;
    MandateRouter router;
    MandateEscrowV1 escrowImpl;
    Market market;

    uint256 kycKey = 0xC0FFEE;
    address kycSigner;
    uint256 constant CAP = 100_000e6;

    function setUp() public override {
        super.setUp();
        kycSigner = vm.addr(kycKey);

        vm.startPrank(owner);
        router = MandateRouter(address(new ERC1967Proxy(
            address(new MandateRouter()),
            abi.encodeCall(MandateRouter.initialize, (owner, address(managerRegistry), address(fundraise)))
        )));
        factory = MandateFactory(address(new ERC1967Proxy(
            address(new MandateFactory()),
            abi.encodeCall(MandateFactory.initialize, (owner, kycSigner))
        )));
        market = Market(address(new ERC1967Proxy(
            address(new Market()), abi.encodeCall(Market.initialize, (address(managerRegistry)))
        )));

        escrowImpl = new MandateEscrowV1(
            address(usdc), address(fundraise), address(managerRegistry), address(router), address(new Lending8Placeholder())
        );
        factory.registerImplementation(1, address(escrowImpl));

        managerRegistry.setMandateFactory(address(factory));
        managerRegistry.setMarketAddress(address(market));
        fundraise.setMandateRouter(address(router));
        vm.stopPrank();
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    /// @dev WALLET, so the split is observable: interest leaves the escrow, principal stays.
    function _mandate(address user, InterestDirection direction) internal returns (MandateEscrowV1 e) {
        return _mandate(user, direction, 10_000);
    }

    function _mandate(address user, InterestDirection direction, uint16 limitBps)
        internal
        returns (MandateEscrowV1 e)
    {
        ImmutableParamsV1 memory p =
            ImmutableParamsV1({ interestDirection: uint8(direction), projectLimitBps: limitBps });

        bytes32 inner = keccak256(
            abi.encodePacked(user, keccak256(abi.encode(p)), uint16(1), address(factory), block.chainid)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(kycKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)));

        vm.prank(user);
        e = MandateEscrowV1(factory.createMandate(p, abi.encodePacked(r, s, v)));
    }

    function _fund(MandateEscrowV1 e, uint256 amount) internal {
        vm.prank(owner);
        usdc.mint(address(e), amount);
    }

    /// @dev Setup creates projects in ComingSoon; allocate only takes Open.
    function _openProject() internal returns (uint256 pid) {
        pid = _createProject(CAP, CAP);
        vm.prank(manager);
        fundraise.moveProjectStage(pid);
    }

    function _collect(uint256 pid) internal {
        vm.prank(operator);
        fundraise.claimForMandate(pid, investor, bytes32(0));
    }

    function _position(address who, uint256 pid) internal view returns (uint256 inv, uint256 cl) {
        (inv, cl) = fundraise.investorInfo(who, pid);
    }

    // ── the size the limit is taken from ──────────────────────────────────────

    /// The per-project cap is mandateSize * projectLimitBps / 10000 — the interface says so and
    /// the code says it in those words. This keeps the two the same: spell the sum out a second
    /// time and the base the cap is taken from drifts from the figure named mandateSize, with
    /// nothing to notice it. The placement below covers the other half — moving money into a
    /// project must not move the base, or a mandate could fill one project ticket by ticket.
    function test_the_cap_is_taken_from_the_size_the_interface_names() public {
        uint16 limitBps = 2_500; // a quarter, so the multiplication is not the identity
        MandateEscrowV1 e = _mandate(investor, InterestDirection.WALLET, limitBps);
        _fund(e, 40_000e6);
        uint256 pid = _openProject();

        (uint256 cap, , ) = e.projectLimit(pid);
        assertEq(e.mandateSize(), 40_000e6, "nothing placed yet, so size is the balance");
        assertEq(cap, (e.mandateSize() * limitBps) / 10_000, "cap is not taken from mandateSize");
        assertEq(cap, 10_000e6, "and the quarter is a real quarter");

        vm.prank(operator);
        e.allocate(pid, address(0));

        // Placing moves money from the balance into outstanding principal, so the base — and with
        // it the cap — must not move. This is what stops a mandate filling one project by tickets.
        assertEq(e.mandateSize(), 40_000e6, "placing changed the size the limit is taken from");
        (uint256 capAfter, uint256 exposure, uint256 room) = e.projectLimit(pid);
        assertEq(capAfter, cap, "cap drifted after a placement");
        assertEq(exposure, 10_000e6, "the placement is the exposure");
        assertEq(room, 0, "and the project is full for this mandate");
    }

    // ── the scale the rate is quoted in ───────────────────────────────────────

    /// The escrow divides investorInterestRate by a constant of its own. Nothing else holds that
    /// constant to Fundraise's, and the stub suites cannot: they supply the rate themselves, so
    /// both sides can be wrong together. Getting it wrong by a factor of a hundred makes the
    /// waterfall call every payout interest, and under WALLET the principal leaves the mandate.
    function test_the_interest_budget_uses_fundraise_scale() public {
        (MandateEscrowV1 e, uint256 pid) = _placedAndFunded(InterestDirection.WALLET);

        // one payout larger than the whole interest budget, so the boundary is crossed at once
        _repay(pid, 120_000e6);
        _collect(pid);

        uint256 rate = INVESTOR_INTEREST;
        assertEq(fundraise.BASIS_POINTS(), 1_000_000, "the scale the rate is quoted in");
        assertEq(usdc.balanceOf(investor), (CAP * rate) / fundraise.BASIS_POINTS(), "interest");
        assertEq(e.freeBalance(), CAP, "principal");
    }

    // ── the full cycle ──────────────────────────────────────────────────────────

    /// Create, top up, place, get repaid, place again — on the real contracts end to end.
    function test_full_cycle_create_fund_allocate_repay_reallocate() public {
        MandateEscrowV1 e = _mandate(investor, InterestDirection.KEEP);
        _fund(e, 10_000e6);

        uint256 pid = _openProject();
        vm.prank(operator);
        e.allocate(pid, address(0));

        (uint256 placed, ) = _position(investor, pid);
        assertEq(placed, 10_000e6, "the whole free balance went in");
        assertEq(router.routes(investor, pid), address(e), "and the mandate enrolled itself");
        assertEq(e.freeBalance(), 0);

        // the project fills up, funds and repays in full
        _investAs(investor2, pid, CAP - 10_000e6, address(0));
        _fundProject(pid);
        _repayFull(pid);

        _collect(pid);
        assertEq(e.freeBalance(), 12_000e6, "principal and interest both stayed under KEEP");

        // and the money is placeable again
        uint256 pid2 = _openProject();
        vm.prank(operator);
        e.allocate(pid2, address(0));
        (uint256 placed2, ) = _position(investor, pid2);
        assertEq(placed2, 12_000e6, "reallocated, interest included");
    }

    // ── position moves are invisible to the split ───────────────────────────────

    /// The waterfall reads invested and claimed from Fundraise, and listing a lot rewrites both.
    /// It must come out the same as if the lot had never been listed.
    function test_split_survives_listing_and_cancelling_a_lot() public {
        (MandateEscrowV1 e, uint256 pid) = _placedAndFunded(InterestDirection.WALLET);

        _repay(pid, 20_000e6); // interest only so far
        _collect(pid);
        uint256 interestBefore = usdc.balanceOf(investor);
        assertGt(interestBefore, 0, "interest went to the wallet");

        // the owner lists the position and changes their mind
        vm.prank(investor);
        uint256 saleId = market.sell(pid, 1e6, 0);
        (uint256 inv, ) = _position(investor, pid);
        assertEq(inv, 0, "the books read as if the owner left");

        vm.prank(investor);
        market.cancel(saleId);

        _repay(pid, 100_000e6); // brings the total to exactly principal + interest
        _collect(pid);

        // interest is capped by the budget however the position travelled
        uint256 budget = (CAP * INVESTOR_INTEREST) / BASIS_POINTS;
        assertEq(usdc.balanceOf(investor), budget, "the whole interest budget, no more");
        assertEq(e.freeBalance(), CAP, "and the principal, no less");
    }

    /// Selling shrinks invested and claimed together, so the next payout must split on the
    /// smaller position without the earlier payouts confusing the waterfall.
    function test_split_after_selling_half_the_position() public {
        (, uint256 pid) = _placedAndFunded(InterestDirection.WALLET);

        _repay(pid, 20_000e6);
        _collect(pid);

        // list the whole position and let investor2 buy it
        vm.prank(investor);
        uint256 saleId = market.sell(pid, 1e6, 0);
        _buy(saleId, investor2);

        (uint256 inv, ) = _position(investor, pid);
        assertEq(inv, 0, "the position is the buyer's now");

        _repay(pid, 100_000e6);

        // The whole position was sold, so Fundraise has nothing recorded against the owner and
        // refuses the collection outright — the mandate is simply no longer in this project.
        vm.expectRevert(Fundraise.NoInvestmentFound.selector);
        _collect(pid);
    }

    /// A project detached and routed back keeps its numbers, so the payout after it splits right.
    function test_split_after_a_project_is_detached_and_routed_back() public {
        (MandateEscrowV1 e, uint256 pid) = _placedAndFunded(InterestDirection.WALLET);

        vm.startPrank(investor);
        router.detach(pid);
        router.setRoute(pid, address(e));
        vm.stopPrank();

        _repayFull(pid);
        _collect(pid);

        uint256 budget = (CAP * INVESTOR_INTEREST) / BASIS_POINTS;
        assertEq(usdc.balanceOf(investor), budget, "interest out");
        assertEq(e.freeBalance(), CAP, "principal in");
    }

    // ── internals ───────────────────────────────────────────────────────────────

    /// @dev A mandate holding the whole of a funded project, so the arithmetic is round.
    function _placedAndFunded(InterestDirection direction)
        internal
        returns (MandateEscrowV1 e, uint256 pid)
    {
        e = _mandate(investor, direction);
        _fund(e, CAP);

        pid = _openProject();
        vm.prank(operator);
        e.allocate(pid, address(0));
        _fundProject(pid);
    }

    function _buy(uint256 saleId, address buyer) internal {
        vm.prank(owner);
        usdc.mint(buyer, 100_000e6);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);

        bytes32 inner = keccak256(abi.encodePacked(buyer, saleId));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(backendPk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner)));

        vm.prank(buyer);
        market.buy(saleId, abi.encodePacked(r, s, v));
    }
}
