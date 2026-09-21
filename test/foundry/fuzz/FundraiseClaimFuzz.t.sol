// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fuzz over the proportional distribution: claimableShare = totalRepaid * invested
///         / totalInvested, one division, floored.
/// @dev Where an exact answer exists it is asserted exactly. Across several holders there is none
///      to assert: each share is floored, so the sum falls short of the pool by an amount that
///      depends on the inputs. Both ends are bounded instead, and the bounds are the tightest the
///      arithmetic permits — the exact shares sum to the pool, so the fractional parts they drop
///      sum to a whole number below the holder count, never to the count itself.
contract FundraiseClaimFuzzTest is Setup {
    // ═══════════════════════════════════════════════════════════════
    //          PURE MATH FUZZ (no contract interaction)
    // ═══════════════════════════════════════════════════════════════

    /// @notice The only holder takes everything, nothing rounds away.
    function testFuzz_claimMath_singleInvestor(uint256 invested, uint256 totalRepaid) public pure {
        invested = bound(invested, 1e6, 1_000_000e6);
        totalRepaid = bound(totalRepaid, 0, invested * 3);

        assertEq(Math.mulDiv(totalRepaid, invested, invested), totalRepaid, "all of it");
    }

    /// @notice Two investors: sum of claims never exceeds totalRepaid
    function testFuzz_claimMath_twoInvestors_noOverclaim(
        uint256 amount1,
        uint256 amount2,
        uint256 totalRepaid
    ) public pure {
        amount1 = bound(amount1, 1e6, 500_000e6);
        amount2 = bound(amount2, 1e6, 500_000e6);
        uint256 totalInvested = amount1 + amount2;
        totalRepaid = bound(totalRepaid, 0, totalInvested * 3);

        uint256 claim1 = Math.mulDiv(totalRepaid, amount1, totalInvested);
        uint256 claim2 = Math.mulDiv(totalRepaid, amount2, totalInvested);

        assertLe(claim1 + claim2, totalRepaid, "never more than came in");
        assertGe(claim1 + claim2 + 1, totalRepaid, "and short by less than a holder");
    }

    /// @notice Three investors: dust amount from rounding loss
    function testFuzz_claimMath_threeInvestors_dustBounded(
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 totalRepaid
    ) public pure {
        a1 = bound(a1, 1e6, 300_000e6);
        a2 = bound(a2, 1e6, 300_000e6);
        a3 = bound(a3, 1e6, 300_000e6);
        uint256 total = a1 + a2 + a3;
        totalRepaid = bound(totalRepaid, 0, total * 3);

        uint256 sumClaims = Math.mulDiv(totalRepaid, a1, total)
            + Math.mulDiv(totalRepaid, a2, total)
            + Math.mulDiv(totalRepaid, a3, total);

        assertLe(sumClaims, totalRepaid, "never more than came in");
        // Two units across three holders, which is all three floors can drop between them. Any
        // slack beyond that would let a loss that scales with the pool pass as rounding.
        assertLe(totalRepaid - sumClaims, 2, "less than one unit per holder");
    }

    // ═══════════════════════════════════════════════════════════════
    //     END-TO-END FUZZ (full contract interaction)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Fuzz invest amount + repay amount for single investor
    function testFuzz_e2e_singleInvestorClaimExact(uint256 investAmount, uint256 repayPercent) public {
        investAmount = bound(investAmount, 1_000e6, 40_000e6); // within hardCap
        repayPercent = bound(repayPercent, 10, 120); // 10% to 120% of totalOwed

        uint256 pid = _createProject(1_000e6, 40_000e6);
        _investAs(investor, pid, investAmount, inviter);
        _fundProject(pid);

        // Calculate total owed
        uint256 totalOwed = investAmount + (investAmount * INVESTOR_INTEREST) / BASIS_POINTS;
        uint256 repayAmount = (totalOwed * repayPercent) / 100;
        if (repayAmount > totalOwed) repayAmount = totalOwed;

        _repay(pid, repayAmount);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        uint256 claimed = usdc.balanceOf(investor) - balBefore;

        // Single investor: claimed should equal the repay amount
        assertEq(claimed, repayAmount, "Single investor should get exact repayment");
    }

    /// @notice Fuzz two investors: no over-claim in contract
    function testFuzz_e2e_twoInvestors_noOverclaim(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1_000e6, 19_000e6);
        amount2 = bound(amount2, 1_000e6, 19_000e6);

        uint256 hardCap = amount1 + amount2 + 1e6; // ensure within cap
        uint256 pid = _createProject(1_000e6, hardCap);

        _investAs(investor, pid, amount1, inviter);
        _investAs(investor2, pid, amount2, address(0));
        _fundProject(pid);
        _repayFull(pid);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        uint256 totalRepaid = inner.totalRepaid;

        vm.prank(investor);
        fundraise.claim(pid, investor);
        vm.prank(investor2);
        fundraise.claim(pid, investor2);

        (, uint256 claimed1) = fundraise.investorInfo(investor, pid);
        (, uint256 claimed2) = fundraise.investorInfo(investor2, pid);

        assertLe(claimed1 + claimed2, totalRepaid, "Over-claim in contract");

        assertLe(totalRepaid - (claimed1 + claimed2), 1, "less than one unit per holder");
    }
}
