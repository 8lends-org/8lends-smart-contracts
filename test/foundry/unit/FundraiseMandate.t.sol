// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Routes only — the router has its own suite. Under test is what Fundraise does with them.
contract RouterStub {
    mapping(address => mapping(uint256 => address)) public routes;

    function setRoute(address owner, uint256 pid, address escrow) external {
        routes[owner][pid] = escrow;
    }
}

contract FactoryStub {
    mapping(address => mapping(address => bool)) public owns;

    function set(address owner, address escrow) external {
        owns[owner][escrow] = true;
    }

    function isEscrowOf(address owner, address escrow) external view returns (bool) {
        return owns[owner][escrow];
    }
}

/// @dev Records what onPayout was handed, so the numbers can be checked rather than trusted.
contract EscrowStub {
    uint256 public calls;
    uint256 public lastPid;
    uint256 public lastFresh;
    uint256 public lastInvested;
    uint256 public lastClaimed;
    uint256 public lastRate;
    bytes32 public lastMarketId;

    function onPayout(
        uint256 pid,
        uint256 fresh,
        uint256 invested,
        uint256 claimed,
        uint256 rate,
        bytes32 marketId
    ) external {
        calls++;
        lastPid = pid;
        lastFresh = fresh;
        lastInvested = invested;
        lastClaimed = claimed;
        lastRate = rate;
        lastMarketId = marketId;
    }

    function place(Fundraise f, IERC20 usdc, address owner, uint256 pid, uint256 amount) external {
        usdc.approve(address(f), amount);
        f.investFromMandate(owner, pid, amount, address(0));
    }
}

contract FundraiseMandateTest is Setup {
    RouterStub router;
    FactoryStub factory;
    EscrowStub escrow;

    address recovery = makeAddr("recovery");
    bytes32 constant MARKET_ID = bytes32(uint256(0xBEEF));
    uint256 constant AMOUNT = 1_000e6;

    function setUp() public override {
        super.setUp();

        router = new RouterStub();
        factory = new FactoryStub();
        escrow = new EscrowStub();
        factory.set(investor, address(escrow));

        vm.startPrank(owner);
        fundraise.setMandateRouter(address(router));
        managerRegistry.setMandateFactory(address(factory));
        vm.stopPrank();
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    /// @dev A funded, fully repaid project the investor holds a position in.
    function _repaidProject() internal returns (uint256 pid) {
        pid = _createProject(AMOUNT, AMOUNT);
        _investAs(investor, pid, AMOUNT, address(0));
        _fundProject(pid);
        _repayFull(pid);
    }

    function _route(uint256 pid) internal {
        router.setRoute(investor, pid, address(escrow));
    }

    function _compromise(address user) internal {
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(user, recovery);
    }

    // ── investFromMandate ───────────────────────────────────────────────────────

    function test_placement_is_recorded_against_the_owner_not_the_escrow() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);
        vm.prank(owner);
        usdc.mint(address(escrow), AMOUNT);

        escrow.place(fundraise, IERC20(address(usdc)), investor, pid, AMOUNT);

        (uint256 invested, ) = fundraise.investorInfo(investor, pid);
        assertEq(invested, AMOUNT, "the owner is the investor");
        (uint256 escrowInvested, ) = fundraise.investorInfo(address(escrow), pid);
        assertEq(escrowInvested, 0, "the escrow is not");
    }

    function test_placement_is_refused_for_an_owner_the_escrow_does_not_belong_to() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);
        vm.prank(owner);
        usdc.mint(address(escrow), AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(Fundraise.NotMandateOf.selector, investor2, address(escrow))
        );
        escrow.place(fundraise, IERC20(address(usdc)), investor2, pid, AMOUNT);
    }

    function test_placement_reverts_while_the_registry_has_no_factory() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);

        // The address is written in a transaction of its own, after the factory is deployed; until
        // then every mandate path is meant to be shut.
        ManagerRegistry fresh = _registryWithoutFactory();
        vm.prank(owner);
        fundraise.setManagerRegistry(address(fresh));

        vm.expectRevert(Fundraise.NoMandateFactory.selector);
        escrow.place(fundraise, IERC20(address(usdc)), investor, pid, AMOUNT);
    }

    // ── outstanding principal ───────────────────────────────────────────────────

    /// The router reports what a mandate still has out, the escrow forwards what came back as
    /// interest, and both read the same claim counter — so the split has to be the same one. Six
    /// real repayments, each checked against onPayout's arithmetic transcribed. Counting all of
    /// totalClaimed as principal is wrong by exactly the interest collected so far.
    function test_outstandingPrincipal_follows_the_interest_first_waterfall() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);
        _investAs(investor, pid, AMOUNT, address(0));
        _fundProject(pid);

        uint256 budget = (AMOUNT * INVESTOR_INTEREST) / BASIS_POINTS;
        assertEq(fundraise.outstandingPrincipal(investor, pid), AMOUNT, "nothing back yet");

        uint256 claimed;
        uint256 principalBack;
        for (uint256 i = 0; i < 6; i++) {
            _repay(pid, (AMOUNT + budget) / 6);
            vm.prank(investor);
            fundraise.claim(pid, investor);

            (, uint256 nowClaimed) = fundraise.investorInfo(investor, pid);
            uint256 fresh = nowClaimed - claimed;
            // onPayout's split, transcribed: interest until the budget is spent, principal after.
            uint256 interest = claimed >= budget ? 0 : Math.min(fresh, budget - claimed);
            principalBack += fresh - interest;
            claimed = nowClaimed;

            assertEq(
                fundraise.outstandingPrincipal(investor, pid),
                AMOUNT - principalBack,
                "the view disagrees with the waterfall the escrow settles by"
            );
            if (i == 0) assertEq(principalBack, 0, "the first repayment is interest, not principal");
        }

        assertGt(claimed, AMOUNT, "more was claimed than was put in");
        assertEq(fundraise.outstandingPrincipal(investor, pid), 0, "and the principal is all back");
    }

    /// Nothing caps a repayment at what is owed, so the claim counter can pass principal plus
    /// budget. The subtraction floors there rather than wrapping.
    function test_outstandingPrincipal_floors_when_the_borrower_overpays() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);
        _investAs(investor, pid, AMOUNT, address(0));
        _fundProject(pid);

        uint256 owed = AMOUNT + (AMOUNT * INVESTOR_INTEREST) / BASIS_POINTS;
        _repay(pid, owed * 2);
        vm.prank(investor);
        fundraise.claim(pid, investor);

        (, uint256 claimed) = fundraise.investorInfo(investor, pid);
        assertGt(claimed, owed, "claimed past principal and budget both");
        assertEq(fundraise.outstandingPrincipal(investor, pid), 0);
    }

    // ── payout target ───────────────────────────────────────────────────────────

    function test_payout_goes_to_the_wallet_without_a_route() public {
        uint256 pid = _repaidProject();
        uint256 before = usdc.balanceOf(investor);

        vm.prank(investor);
        fundraise.claim(pid, investor);

        assertGt(usdc.balanceOf(investor), before);
    }

    /// Money must not keep going to a contract whose owner key is in someone else's hands.
    function test_compromise_beats_the_mandate_route() public {
        uint256 pid = _repaidProject();
        _route(pid);
        _compromise(investor);

        vm.prank(attacker);
        fundraise.claimForMandate(pid, investor, MARKET_ID);

        assertGt(usdc.balanceOf(recovery), 0, "paid to the recovery address");
        assertEq(usdc.balanceOf(address(escrow)), 0, "and not to the mandate");
        assertEq(escrow.calls(), 0, "no split call on money that never arrived");
    }

    // ── claim authorisation ─────────────────────────────────────────────────────

    /// The manager's blanket right to claim for a user is what this upgrade removes.
    function test_nobody_may_claim_for_a_clean_address() public {
        uint256 pid = _repaidProject();

        vm.expectRevert(Fundraise.NotAllowed.selector);
        vm.prank(manager);
        fundraise.claim(pid, investor);

        vm.expectRevert(Fundraise.NotAllowed.selector);
        vm.prank(operator);
        fundraise.claim(pid, investor);
    }

    function test_anyone_may_claim_for_a_compromised_address() public {
        uint256 pid = _repaidProject();
        _compromise(investor);

        vm.prank(attacker);
        fundraise.claim(pid, investor);

        assertGt(usdc.balanceOf(recovery), 0);
        assertEq(usdc.balanceOf(investor), 0, "never back to the stolen wallet");
    }

    // ── claim vs claimForMandate ────────────────────────────────────────────────

    /// Allowing it would deliver the payout unsplit, and interest would never leave the escrow.
    function test_plain_claim_reverts_on_a_routed_project() public {
        uint256 pid = _repaidProject();
        _route(pid);

        vm.expectRevert(abi.encodeWithSelector(Fundraise.ProjectIsRouted.selector, pid));
        vm.prank(investor);
        fundraise.claim(pid, investor);
    }

    /// The exception: the route does not apply to them, and this is the support button.
    function test_plain_claim_passes_on_a_routed_project_of_a_compromised_owner() public {
        uint256 pid = _repaidProject();
        _route(pid);
        _compromise(investor);

        vm.prank(attacker);
        fundraise.claim(pid, investor);

        assertGt(usdc.balanceOf(recovery), 0);
    }

    function test_claimForMandate_reverts_on_an_unrouted_project() public {
        uint256 pid = _repaidProject();

        vm.expectRevert(abi.encodeWithSelector(Fundraise.ProjectNotRouted.selector, pid));
        vm.prank(investor);
        fundraise.claimForMandate(pid, investor, MARKET_ID);
    }

    function test_claimForMandate_hands_the_escrow_what_it_needs_to_split() public {
        uint256 pid = _repaidProject();
        _route(pid);

        vm.prank(operator);
        fundraise.claimForMandate(pid, investor, MARKET_ID);

        (, uint256 claimed) = fundraise.investorInfo(investor, pid);
        assertEq(usdc.balanceOf(address(escrow)), claimed, "the whole payout landed on the escrow");
        assertEq(escrow.calls(), 1);
        assertEq(escrow.lastPid(), pid);
        assertEq(escrow.lastFresh(), claimed, "first payout, so fresh is the whole of it");
        assertEq(escrow.lastInvested(), AMOUNT);
        assertEq(escrow.lastClaimed(), claimed, "after the increment, not before");
        assertEq(escrow.lastRate(), INVESTOR_INTEREST);
        assertEq(escrow.lastMarketId(), MARKET_ID);
    }

    /// Nothing repaid yet: the call succeeds, but the escrow is not told about a payout that never
    /// arrived — under LEND a zero would reach Lending8 and revert there.
    function test_claimForMandate_leaves_the_escrow_alone_on_a_zero_payout() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);
        _investAs(investor, pid, AMOUNT, address(0));
        _fundProject(pid);
        _route(pid);

        vm.prank(operator);
        fundraise.claimForMandate(pid, investor, MARKET_ID);

        assertEq(escrow.calls(), 0, "no split call");
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_claimForMandate_is_refused_to_a_stranger_on_a_clean_address() public {
        uint256 pid = _repaidProject();
        _route(pid);

        vm.expectRevert(Fundraise.NotAllowed.selector);
        vm.prank(attacker);
        fundraise.claimForMandate(pid, investor, MARKET_ID);
    }

    // ── withdrawInvestment ──────────────────────────────────────────────────────

    /// Without this branch the principal would wait for a button the owner does not know about.
    function test_operator_refunds_a_routed_cancelled_project() public {
        uint256 pid = _cancelledProject();
        _route(pid);

        vm.expectEmit(true, true, true, true, address(fundraise));
        emit Fundraise.InvestmentRefunded(pid, investor, address(escrow), AMOUNT);
        vm.prank(operator);
        fundraise.withdrawInvestment(pid, investor);

        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
    }

    function test_operator_refund_reverts_without_a_route() public {
        uint256 pid = _cancelledProject();

        vm.expectRevert(Fundraise.NotAllowed.selector);
        vm.prank(operator);
        fundraise.withdrawInvestment(pid, investor);
    }

    function test_refund_event_is_silent_when_the_recipient_is_the_investor() public {
        uint256 pid = _cancelledProject();

        vm.recordLogs();
        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != Fundraise.InvestmentRefunded.selector,
                "the plain WithdrawInvestment already says it"
            );
        }
    }

    // ── regressions ─────────────────────────────────────────────────────────────

    /// Rewards read the registry directly and never the router, so a mandate cannot swallow them.
    function test_rewards_are_recorded_against_the_wallet_under_a_route() public {
        uint256 pid = _createProject(AMOUNT, AMOUNT);
        router.setRoute(investor, pid, address(escrow));
        _investAs(investor, pid, AMOUNT, inviter);

        (, uint256 investorTokens, ) = rewardSystem.projectReferrals(investor, pid);
        assertGt(investorTokens, 0, "the reward did accrue");
        (, uint256 escrowTokens, ) = rewardSystem.projectReferrals(address(escrow), pid);
        assertEq(escrowTokens, 0, "and not to the mandate");
    }

    /// The pre-upgrade behaviour, which is what makes deploying ahead of the router safe.
    function test_a_zero_router_leaves_every_project_unrouted() public {
        uint256 pid = _repaidProject();
        _route(pid);

        vm.prank(owner);
        fundraise.setMandateRouter(address(0));

        vm.prank(investor);
        fundraise.claim(pid, investor);
        assertGt(usdc.balanceOf(investor), 0);
    }

    // ── internals ───────────────────────────────────────────────────────────────

    function _cancelledProject() internal returns (uint256 pid) {
        pid = _createProject(AMOUNT * 2, AMOUNT * 2);
        _investAs(investor, pid, AMOUNT, address(0));
        vm.warp(block.timestamp + 8 days);
        vm.prank(manager);
        fundraise.cancelProject(pid);
    }

    function _registryWithoutFactory() internal returns (ManagerRegistry fresh) {
        ManagerRegistry impl = new ManagerRegistry();
        vm.prank(owner);
        fresh = ManagerRegistry(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(ManagerRegistry.initialize, ())
        )));
    }
}
