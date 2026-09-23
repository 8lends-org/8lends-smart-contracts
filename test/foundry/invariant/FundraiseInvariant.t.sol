// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import "./handlers/FundraiseHandler.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Invariant tests for Fundraise contract
/// @dev Verifies protocol-wide properties hold under random action sequences:
///      1. No over-claim: sum of all claims <= totalRepaid
///      2. USDC conservation: all USDC is accounted for
///      3. Investment consistency: totalInvested == sum of individual amounts
///      4. No under-pay: what each holder has plus what is still theirs is their exact share
///      5. Positions add up: a holder's position list sums to their aggregate investedAmount
///
///      The fourth is the other half of the first: the rest bound the protocol from above — never
///      pay out more than came in — and this one bounds it from below, so a claim that quietly
///      short-changes every holder cannot pass. The fifth holds up the aggregate everything else
///      apportions by, positionOwed and positionClaimed included.
contract FundraiseInvariantTest is Setup {
    FundraiseHandler handler;
    uint256 pid;
    address[] investorList;

    function setUp() public override {
        super.setUp();

        pid = _createProject(5_000e6, 50_000e6);
        // A project is created in ComingSoon and the handler only invests in Open ones, so it has
        // to be moved before the run starts. An empty project satisfies every invariant below
        // vacuously, and nothing in the run would say so.
        vm.prank(manager);
        fundraise.moveProjectStage(pid);

        investorList.push(investor);
        investorList.push(investor2);
        investorList.push(makeAddr("investor3"));

        handler = new FundraiseHandler(
            fundraise,
            usdc,
            managerRegistry,
            backendPk,
            owner,
            manager,
            borrower,
            investorList,
            pid
        );

        // transferPosition asks only that its caller be the registered market.
        vm.prank(owner);
        managerRegistry.setMarketAddress(address(handler));

        targetContract(address(handler));
    }

    /// @notice A holder's positions add up to their aggregate investedAmount.
    /// @dev The same money is kept twice: the aggregate a claim reads, the list the market sells
    ///      from. Let them drift and every apportionment divides by the wrong denominator.
    function invariant_positionsSumToTheAggregate() public view {
        for (uint256 i = 0; i < investorList.length; i++) {
            address holder = investorList[i];
            Fundraise.InvestorInfo[] memory positions = fundraise.getInvestorPositions(holder, pid);

            uint256 sum;
            for (uint256 j = 0; j < positions.length; j++) sum += positions[j].investedAmount;

            (uint256 aggregate, ) = fundraise.investorInfo(holder, pid);
            assertEq(sum, aggregate, "INVARIANT VIOLATED: positions do not add up to the aggregate");
        }
    }

    /// @notice What a holder has taken, plus what is still owed to them, is their exact share.
    /// @dev Truncating a share leaves the difference permanently unreachable — neither claimed
    ///      nor claimable — so this equality is what catches it, and the aggregate bound below is
    ///      what says how much can be left in total.
    function invariant_noUnderPay() public view {
        if (!handler.ghost_isFunded() || handler.ghost_totalRepaid() == 0) return;

        (, , uint256 totalInvested, , , , , Fundraise.InnerProjectStruct memory inner) =
            fundraise.projects(pid);
        if (totalInvested == 0) return;

        uint256 excess;
        for (uint256 i = 0; i < investorList.length; i++) {
            address inv = investorList[i];
            (uint256 invested, uint256 claimed) = fundraise.investorInfo(inv, pid);
            if (invested == 0) continue;

            uint256 share = Math.mulDiv(inner.totalRepaid, invested, totalInvested);

            assertGe(
                claimed + fundraise.availableToClaim(pid, inv),
                share,
                "INVARIANT VIOLATED: part of a holder's share is reachable by nobody"
            );

            if (claimed > share) excess += claimed - share;
        }

        // A watermark runs ahead of its share only through transferPosition rounding up, and only
        // by a unit each time. Summed, not per holder: a transfer conserves the watermark exactly
        // while splitting one share into two truncated ones, so the excess it creates lands on the
        // receiver and is then carried along by every later transfer out of them.
        assertLe(
            excess,
            handler.calls_transfer(),
            "INVARIANT VIOLATED: watermarks are further ahead than the transfers put them"
        );
    }

    /// @notice Across the project, at most one unit per holder stays behind.
    function invariant_dustIsOneUnitPerHolder() public view {
        if (!handler.ghost_isFunded() || handler.ghost_totalRepaid() == 0) return;

        uint256 reachable;
        uint256 holders;
        for (uint256 i = 0; i < investorList.length; i++) {
            (uint256 invested, uint256 claimed) = fundraise.investorInfo(investorList[i], pid);
            if (invested == 0) continue;
            holders++;
            reachable += claimed + fundraise.availableToClaim(pid, investorList[i]);
        }

        // Guarded: a rounded-up watermark can put reachable above what was repaid — nothing stuck.
        uint256 stuck = handler.ghost_totalRepaid() > reachable ? handler.ghost_totalRepaid() - reachable : 0;

        assertLe(
            stuck,
            holders == 0 ? 0 : holders - 1,
            "INVARIANT VIOLATED: more than rounding is stuck in the contract"
        );
    }

    /// @notice Sum of all claims never exceeds total repaid
    function invariant_noOverClaim() public view {
        if (handler.ghost_totalRepaid() == 0) return;
        assertLe(
            handler.ghost_totalClaimed(),
            handler.ghost_totalRepaid(),
            "INVARIANT VIOLATED: total claimed > total repaid"
        );
    }

    /// @notice USDC balance of Fundraise contract is consistent with ghost accounting
    /// @dev Balance = totalInvested - platformFee - borrowerReceived + totalRepaid - totalClaimed
    function invariant_usdcConservation() public view {
        uint256 expectedBalance;
        if (handler.ghost_isFunded()) {
            // After funding: USDC left = totalRepaid - totalClaimed
            // (invested USDC went to borrower + treasury)
            expectedBalance = handler.ghost_totalRepaid() - handler.ghost_totalClaimed();
        } else {
            // Before funding: all invested USDC is in the contract
            expectedBalance = handler.ghost_totalInvested();
        }

        uint256 actualBalance = usdc.balanceOf(address(fundraise));
        assertEq(actualBalance, expectedBalance, "INVARIANT VIOLATED: USDC balance mismatch");
    }

    /// @notice totalInvested in project matches ghost tracking
    function invariant_investmentAccounting() public view {
        (,, uint256 contractTotalInvested,,,,,) = fundraise.projects(pid);
        assertEq(
            contractTotalInvested,
            handler.ghost_totalInvested(),
            "INVARIANT VIOLATED: investment accounting mismatch"
        );
    }
}
