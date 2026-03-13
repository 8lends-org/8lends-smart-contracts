// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Fuzz tests for Rewards2 vesting unlock calculations
contract RewardVestingFuzzTest is Setup {
    uint256 constant BP = 1_000_000;
    uint256 constant WEEKLY_UNLOCK = 25_000; // 2.5%
    uint256 constant VESTING_WEEKS = 40;

    // ═══════════════════════════════════════════════════════════════
    //     PURE MATH: vesting unlock formula
    // ═══════════════════════════════════════════════════════════════

    /// @notice Claimable never exceeds totalAmount
    function testFuzz_vestingMath_claimableNeverExceedsTotal(
        uint256 totalAmount,
        uint256 weeksPassed
    ) public pure {
        totalAmount = bound(totalAmount, 1e18, 10_000_000e18);
        weeksPassed = bound(weeksPassed, 0, 200);

        uint256 weeksUnlocked = weeksPassed + 1;

        uint256 totalUnlocked;
        if (weeksUnlocked >= VESTING_WEEKS) {
            totalUnlocked = totalAmount;
        } else {
            totalUnlocked = (totalAmount * weeksUnlocked * WEEKLY_UNLOCK) / BP;
            if (totalUnlocked > totalAmount) {
                totalUnlocked = totalAmount;
            }
        }

        assertLe(totalUnlocked, totalAmount, "Unlocked should never exceed total");
    }

    /// @notice Unlock is monotonically increasing with time
    function testFuzz_vestingMath_monotonicallyIncreasing(
        uint256 totalAmount,
        uint256 weeks1,
        uint256 weeks2
    ) public pure {
        totalAmount = bound(totalAmount, 1e18, 10_000_000e18);
        weeks1 = bound(weeks1, 0, 100);
        weeks2 = bound(weeks2, weeks1, 100);

        uint256 unlock1 = _calcUnlock(totalAmount, weeks1);
        uint256 unlock2 = _calcUnlock(totalAmount, weeks2);

        assertGe(unlock2, unlock1, "Later time should unlock >= earlier time");
    }

    /// @notice At week 0, exactly 2.5% is unlocked
    function testFuzz_vestingMath_weekZeroUnlock(uint256 totalAmount) public pure {
        totalAmount = bound(totalAmount, 1e18, 10_000_000e18);

        uint256 unlocked = _calcUnlock(totalAmount, 0);
        uint256 expected = (totalAmount * WEEKLY_UNLOCK) / BP;

        assertEq(unlocked, expected, "Week 0 should unlock exactly 2.5%");
    }

    /// @notice At week >= 39, everything is unlocked
    function testFuzz_vestingMath_fullUnlockAfterVestingPeriod(
        uint256 totalAmount,
        uint256 weeksPassed
    ) public pure {
        totalAmount = bound(totalAmount, 1e18, 10_000_000e18);
        weeksPassed = bound(weeksPassed, 39, 200); // weeksUnlocked >= 40

        uint256 unlocked = _calcUnlock(totalAmount, weeksPassed);
        assertEq(unlocked, totalAmount, "Should be fully unlocked");
    }

    // ═══════════════════════════════════════════════════════════════
    //     E2E: Rewards2 contract vesting
    // ═══════════════════════════════════════════════════════════════

    /// @notice Fuzz vesting amount and time, verify getVestingInfo matches math
    function testFuzz_e2e_vestingInfoMatchesMath(uint256 totalAmount, uint256 weeksPassed) public {
        totalAmount = bound(totalAmount, 1e18, 1_000_000e18);
        weeksPassed = bound(weeksPassed, 0, 60);

        // Create vesting
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        vm.prank(owner);
        rewards2.createVesting(users, amounts);

        // Warp
        vm.warp(block.timestamp + weeksPassed * 1 weeks);

        // Get from contract
        (,, uint256 claimable,,) = rewards2.getVestingInfo(investor, 0);

        // Calculate expected
        uint256 expected = _calcUnlock(totalAmount, weeksPassed);

        assertEq(claimable, expected, "Contract vesting should match pure math");
    }

    /// @notice Claim then check remaining is correct
    function testFuzz_e2e_claimThenRemainder(uint256 totalAmount, uint256 weeks1, uint256 weeks2) public {
        totalAmount = bound(totalAmount, 100e18, 100_000e18);
        weeks1 = bound(weeks1, 0, 20);
        weeks2 = bound(weeks2, weeks1 + 1, 50);

        // Create vesting and fund
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        vm.prank(owner);
        rewards2.createVesting(users, amounts);
        vm.prank(owner);
        token.mint(address(rewards2), totalAmount);

        // Claim at weeks1
        vm.warp(block.timestamp + weeks1 * 1 weeks);
        vm.prank(investor);
        rewards2.claim();

        uint256 firstClaim = token.balanceOf(investor);
        uint256 expectedFirst = _calcUnlock(totalAmount, weeks1);
        assertEq(firstClaim, expectedFirst, "First claim amount");

        // Claim at weeks2
        vm.warp(block.timestamp + (weeks2 - weeks1) * 1 weeks);
        vm.prank(investor);
        rewards2.claim();

        uint256 totalClaimed = token.balanceOf(investor);
        uint256 expectedTotal = _calcUnlock(totalAmount, weeks2);
        assertEq(totalClaimed, expectedTotal, "Total claimed after second claim");
    }

    // ═══════════════════════════════════════════════════════════════
    //                       HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _calcUnlock(uint256 totalAmount, uint256 weeksPassed) internal pure returns (uint256) {
        uint256 weeksUnlocked = weeksPassed + 1;
        if (weeksUnlocked >= VESTING_WEEKS) {
            return totalAmount;
        }
        uint256 unlocked = (totalAmount * weeksUnlocked * WEEKLY_UNLOCK) / BP;
        if (unlocked > totalAmount) {
            return totalAmount;
        }
        return unlocked;
    }
}
