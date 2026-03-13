// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Fuzz tests for Fundraise claim math (vulnerability #5 — rounding loss)
/// @dev Tests the proportional distribution formula:
///      investorShare = (investedAmount * BASIS_POINTS) / totalInvested
///      claimableShare = (totalRepaid * investorShare) / BASIS_POINTS
contract FundraiseClaimFuzzTest is Setup {
    uint256 constant BP = 1_000_000;

    // ═══════════════════════════════════════════════════════════════
    //          PURE MATH FUZZ (no contract interaction)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Single investor share calculation never exceeds totalRepaid
    function testFuzz_claimMath_singleInvestor(uint256 invested, uint256 totalRepaid) public pure {
        invested = bound(invested, 1e6, 1_000_000e6);
        totalRepaid = bound(totalRepaid, 0, invested * 3);

        uint256 investorShare = (invested * BP) / invested; // == BP
        uint256 claimable = (totalRepaid * investorShare) / BP;

        assertEq(claimable, totalRepaid, "Single investor should get exact totalRepaid");
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

        uint256 share1 = (amount1 * BP) / totalInvested;
        uint256 share2 = (amount2 * BP) / totalInvested;

        uint256 claim1 = (totalRepaid * share1) / BP;
        uint256 claim2 = (totalRepaid * share2) / BP;

        assertLe(claim1 + claim2, totalRepaid, "Sum of claims exceeds totalRepaid");
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

        uint256 s1 = (a1 * BP) / total;
        uint256 s2 = (a2 * BP) / total;
        uint256 s3 = (a3 * BP) / total;

        uint256 c1 = (totalRepaid * s1) / BP;
        uint256 c2 = (totalRepaid * s2) / BP;
        uint256 c3 = (totalRepaid * s3) / BP;

        uint256 sumClaims = c1 + c2 + c3;
        assertLe(sumClaims, totalRepaid);

        // KNOWN ISSUE: Dust can be significant due to double-division rounding.
        // The formula truncates twice: once for investorShare, once for claimableShare.
        // With large totalRepaid and uneven splits, dust can reach thousands of USDC units.
        if (totalRepaid > 0) {
            uint256 dust = totalRepaid - sumClaims;
            // Dust should be less than 0.1% of totalRepaid (min 3 for tiny amounts)
            uint256 maxDust = totalRepaid / 1000;
            if (maxDust < 3) maxDust = 3;
            assertLe(dust, maxDust, "Dust exceeds 0.1% of totalRepaid");
        }
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

        // KNOWN ISSUE: Dust from rounding can be significant.
        // See vulnerability #5: double-division truncation.
        uint256 dust = totalRepaid - (claimed1 + claimed2);
        // Dust should be less than 0.1% of totalRepaid
        assertLe(dust, totalRepaid / 1000, "Dust exceeds 0.1% of totalRepaid");
    }
}
