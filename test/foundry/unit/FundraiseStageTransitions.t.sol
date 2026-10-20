// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Investing refuses instead of moving the stage on its way past, and the transitions that
///         time alone decides are open to anyone.
contract FundraiseStageTransitionsTest is Setup {
    uint256 pid;
    uint256 deadline;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);
        deadline = block.timestamp + 7 days;
    }

    /// @dev Money and signature only — the call itself is left to the test, so expectRevert lands
    ///      on it and not on the minting in front.
    function _prepare(address who, uint256 _pid, uint256 amount)
        internal
        returns (uint256 nonce, bytes memory sig)
    {
        vm.prank(owner);
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(fundraise), amount);
        nonce = fundraise.userNonces(who) + 1;
        sig = _signInvest(who, _pid, amount, nonce, address(0));
    }

    function _try(address who, uint256 _pid, uint256 amount) internal {
        (uint256 nonce, bytes memory sig) = _prepare(who, _pid, amount);
        vm.prank(who);
        fundraise.investUpdateV2(_pid, amount, nonce, sig, address(0));
    }

    function _stage(uint256 _pid) internal view returns (Fundraise.Stage) {
        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(_pid);
        return inner.stage;
    }

    function _openStageEndAt(uint256 _pid) internal view returns (uint256 endsAt) {
        (,,,,,, endsAt,) = fundraise.projects(_pid);
    }

    // ── the raise refuses instead of failing quietly ────────────────────────────

    function test_investBeforeStartAt_reverts() public {
        uint256 future = _createProjectStartingIn(1 days);
        Fundraise.Stage before = _stage(future);

        (uint256 nonce, bytes memory sig) = _prepare(investor, future, 1_000e6);
        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(Fundraise.ProjectNotStarted.selector, future, block.timestamp + 1 days)
        );
        fundraise.investUpdateV2(future, 1_000e6, nonce, sig, address(0));

        assertEq(uint8(_stage(future)), uint8(before), "a refusal must leave the stage alone");
        (,, uint256 totalInvested,,,,,) = fundraise.projects(future);
        assertEq(totalInvested, 0);
    }

    /// @dev The lazy ComingSoon -> Open stays: the first investor must not depend on someone else
    ///      having called moveProjectStage first.
    function test_firstInvestOpensTheProjectByItself() public {
        uint256 soon = _createProjectStartingIn(1 days);
        vm.warp(block.timestamp + 1 days);

        _try(investor, soon, 1_000e6);

        assertEq(uint8(_stage(soon)), uint8(Fundraise.Stage.Open));
    }

    // ── transitions the clock decides ──────────────────────────────────────────

    function test_anyoneOpensAProjectWhoseStartArrived() public {
        uint256 soon = _createProjectStartingIn(1 days);
        vm.warp(block.timestamp + 1 days);

        vm.prank(attacker);
        fundraise.moveProjectStage(soon);

        assertEq(uint8(_stage(soon)), uint8(Fundraise.Stage.Open));
    }

    /// @dev Closing a live raise forfeits the room left up to the hard cap. That is a decision, and
    ///      opening the deadline branch must not hand it to everyone.
    function test_nobodyButAManagerClosesALiveRaiseEarly() public {
        _investAs(investor, pid, 25_000e6, inviter);

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.moveProjectStage(pid);

        vm.prank(manager);
        fundraise.moveProjectStage(pid);
        assertEq(uint8(_stage(pid)), uint8(Fundraise.Stage.PreFunded));
    }

    function test_nobodyButAManagerCancelsALiveRaise() public {
        _investAs(investor, pid, 10_000e6, inviter);

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.cancelProject(pid);

        vm.prank(manager);
        fundraise.cancelProject(pid);
        assertEq(uint8(_stage(pid)), uint8(Fundraise.Stage.Canceled));
    }

    /// @dev Permissionless, so an id past the end must not mint a status for a project nobody made.
    function test_moveProjectStage_rejectsAnIdThatWasNeverCreated() public {
        vm.prank(attacker);
        vm.expectRevert(Fundraise.ProjectDoesNotExist.selector);
        fundraise.moveProjectStage(99);
    }

    // ── when the raise ended ───────────────────────────────────────────────────

    /// @dev preFundDuration runs from the deadline, not from whenever someone got round to the
    ///      call — otherwise the borrower's window stretches by however long nobody looked.
    function test_settlingLateDoesNotMoveTheEndOfTheRaise() public {
        _investAs(investor, pid, 25_000e6, inviter);
        vm.warp(deadline + 30 days);

        vm.prank(attacker);
        fundraise.moveProjectStage(pid);

        assertEq(_openStageEndAt(pid), deadline, "the raise ended at its deadline");

        // And the borrower's window is already spent, so the project cancels rather than waiting
        // another preFundDuration from today.
        vm.prank(attacker);
        fundraise.cancelProject(pid);
        assertEq(uint8(_stage(pid)), uint8(Fundraise.Stage.Canceled));
    }

    /// @dev An early close really does end the raise now, so there the write stays.
    function test_anEarlyCloseEndsTheRaiseAtThatMoment() public {
        _investAs(investor, pid, 25_000e6, inviter);
        vm.warp(deadline - 1 days);

        vm.prank(manager);
        fundraise.moveProjectStage(pid);

        assertEq(_openStageEndAt(pid), block.timestamp, "closed early, so the raise ended today");
    }

    // ── the money still comes back ─────────────────────────────────────────────

    function test_investorsTakeTheirPrincipalBackAfterTheCancel() public {
        _investAs(investor, pid, 10_000e6, inviter);
        vm.warp(deadline + 1);

        vm.prank(attacker);
        fundraise.cancelProject(pid);

        uint256 before = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);
        assertEq(usdc.balanceOf(investor) - before, 10_000e6);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _createProjectStartingIn(uint256 offset) internal returns (uint256) {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 40_000e6,
            softCap: 20_000e6,
            totalInvested: 0,
            startAt: block.timestamp + offset,
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + offset + 7 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: PLATFORM_FEE,
                totalRepaid: 0,
                borrower: borrower,
                fundedTime: 0,
                loanToken: IERC20(address(usdc)),
                stage: Fundraise.Stage.ComingSoon
            })
        });
        vm.prank(manager);
        return fundraise.createProject(proj, _nextProjectHash());
    }
}
