// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Fuzz tests for Rewards2 vesting unlock calculations
contract RewardVestingFuzzTest is Setup {
    uint256 constant BP = 1_000_000;
    uint256 constant WEEKLY_UNLOCK = 25_000; // 2.5%
    uint256 constant VESTING_WEEKS = 40;
    /// @dev $0.02 per token: six-decimal USDC against an eighteen-decimal token.
    uint256 constant RATE = 20_000;

    // ═══════════════════════════════════════════════════════════════
    //     E2E: Rewards2 contract vesting
    // ═══════════════════════════════════════════════════════════════

    /// @notice Fuzz vesting amount and time, verify getVestingInfo matches math
    /// @dev Both halves in the order the contract requires, skipping whichever is empty.
    function _claimAll(address user) internal {
        (uint256 inTokens, uint256 usdcAmount) = rewards2.getClaimable(user);
        if (inTokens > 0) {
            vm.prank(user);
            rewards2.claimTokens();
        }
        if (usdcAmount > 0) {
            vm.prank(user);
            rewards2.claimUsdc();
        }
    }

    function testFuzz_e2e_vestingInfoMatchesMath(uint256 totalAmount, uint256 weeksPassed) public {
        totalAmount = bound(totalAmount, 1e18, 1_000_000e18);
        weeksPassed = bound(weeksPassed, 0, 60);

        // Create vesting
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;

        vm.prank(owner);
        rewards2.seedVestings(users, amounts);

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
        rewards2.seedVestings(users, amounts);
        vm.prank(admin);
        rewards2.setRedemptionRate(RATE);
        vm.prank(owner);
        usdc.mint(address(rewards2), totalAmount * RATE / 1e18 + 1e6);

        // Claim at weeks1
        vm.warp(block.timestamp + weeks1 * 1 weeks);
        _claimAll(investor);

        // Measured on the running total, not on one slice: what a claim leaves unpaid is the part
        // of a micro-dollar it could not buy, and that joins the next one.
        uint256 firstSlice = _calcUnlock(totalAmount, weeks1);
        assertEq(usdc.balanceOf(investor), firstSlice * RATE / 1e18, "paid for everything unlocked");

        // Claim at weeks2
        vm.warp(block.timestamp + (weeks2 - weeks1) * 1 weeks);
        _claimAll(investor);

        uint256 unlockedByNow = _calcUnlock(totalAmount, weeks2);
        assertEq(usdc.balanceOf(investor), unlockedByNow * RATE / 1e18, "and the carry is not lost");

        // Run the schedule out. Everything above compares one slice with the test's own copy of the
        // formula, so without this a schedule that leaked a little every week would pass.
        vm.warp(block.timestamp + 60 weeks);
        (,, uint256 left,,) = rewards2.getVestingInfo(investor, 0);
        if (left > 0) _claimAll(investor); // weeks2 may already have taken it all

        // What is left over is the part of the last slice too small to buy a whole micro-dollar.
        // It is never written off — it just cannot be paid, so it stays owed.
        (, uint256 claimed,,) = rewards2.vestings(investor, 0);
        assertLt(totalAmount - claimed, 1e18 / RATE, "only sub-micro-dollar dust may be left owed");
        assertEq(usdc.balanceOf(investor), claimed * RATE / 1e18, "paid for every unit it spent");
    }

    /// @notice Tokens paid over the whole schedule are exactly what had unlocked by the cutover,
    ///         and the rest goes in USDC, however the claims fall around it.
    function testFuzz_e2e_cutoverSplitsTheGrant(
        uint256 totalAmount,
        uint256 cutoverWeek,
        uint256 week1,
        uint256 week2
    ) public {
        totalAmount = bound(totalAmount, 100e18, 100_000e18);
        cutoverWeek = bound(cutoverWeek, 0, 50);
        week1 = bound(week1, 0, 60);
        week2 = bound(week2, week1, 60);

        uint256 t0 = block.timestamp;
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalAmount;
        rewards2.seedVestings(users, amounts);
        rewards2.setCutover(t0 + cutoverWeek * 1 weeks);

        vm.prank(admin);
        rewards2.setRedemptionRate(RATE);
        vm.startPrank(owner);
        usdc.mint(address(rewards2), totalAmount * RATE / 1e18 + 1e6);
        token.mint(address(rewards2), totalAmount);
        vm.stopPrank();

        uint256 claims = 0;
        uint256[3] memory at = [week1, week2, uint256(61)];
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(t0 + at[i] * 1 weeks);
            (uint256 inTokens, uint256 usdcAmount) = rewards2.getClaimable(investor);
            if (inTokens + usdcAmount == 0) continue;
            _claimAll(investor);
            claims++;
        }

        uint256 tokenEra = _calcUnlock(totalAmount, cutoverWeek);
        assertEq(token.balanceOf(investor), tokenEra, "tokens: exactly what unlocked by the cutover");

        uint256 usdcDue = (totalAmount - tokenEra) * RATE / 1e18;
        assertLe(usdc.balanceOf(investor), usdcDue, "never more USDC than the rest is worth");
        assertGe(usdc.balanceOf(investor) + claims, usdcDue, "short by at most rounding, one unit a claim");
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
