// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice The additional-unlock branch of Rewards2 vesting — a bonus granted for selling which,
///         once used, is never taken back. Rewards2.sol:263-279 adds it on top of the weekly
///         schedule and caps the sum at the grant; the ratchet that remembers it is written in one
///         place only, claimAndSellTokens (Rewards2.sol:511-512).
/// @dev The properties below are stated as behaviour, not as formulas. A model that reimplements
///      _calculateVestingAmount and compares would agree with a wrong formula as readily as with a
///      right one — the weekly-only model in RewardVestingFuzz is exactly that shape, which is why
///      it says nothing about this branch. What is asserted here instead: a ceiling that holds, a
///      bonus that cannot be clawed back, a sell bonus that does not leak into the ordinary claim,
///      and the whole grant arriving in the end whatever the percentage did along the way.
contract RewardAdditionalUnlockFuzzTest is Setup {
    /// @dev Rewards2 ships with 2.5% a week over 40 weeks; a bonus has to beat one week's unlock to
    ///      be distinguishable from the schedule catching up.
    uint256 constant WEEKLY = 25_000;
    uint256 constant FULL = 1_000_000;

    address holder;

    function setUp() public override {
        super.setUp();
        holder = makeAddr("vestingHolder");
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    function _vest(uint256 amount) internal {
        address[] memory users = new address[](1);
        users[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.startPrank(owner);
        rewards2.createVesting(users, amounts);
        // Twice the grant: in production the contract holds everyone's grants at once, and with
        // exactly one the balance check becomes the binding limit and hides a broken ceiling.
        token.mint(address(rewards2), amount * 2);
        vm.stopPrank();
    }

    function _setBonus(uint256 pct) internal {
        vm.prank(manager);
        rewards2.setAdditionalUnlock(pct);
    }

    /// @dev What the ordinary claim would pay: includeCurrentBonus is false on that path.
    function _claimable() internal view returns (uint256 claimable) {
        (, claimable, , , ) = rewards2.getBalances(holder);
    }

    /// @dev What the sell path would release: the current percentage counts there.
    function _sellable() internal view returns (uint256 tokens) {
        (tokens, , ) = rewards2.getClaimAndSellAmounts(holder);
    }

    function _released() internal view returns (uint256 claimed) {
        (, claimed, , ) = rewards2.vestings(holder, 0);
    }

    function _claim() internal {
        if (_claimable() == 0) return;
        vm.prank(holder);
        rewards2.claim();
    }

    function _sell() internal {
        if (_sellable() == 0) return;
        vm.prank(holder);
        rewards2.claimAndSellTokens(0);
    }

    // ── 1. the ceiling holds ────────────────────────────────────────────────────

    /// The bonus is added on top of the weekly schedule, so the two together can exceed the grant.
    /// Whatever the percentage and however many weeks have passed, no more than the grant may be
    /// released — and the setter's own bound of 100% is not what enforces it.
    function testFuzz_theGrantIsNeverExceeded(uint256 grant, uint256 pct, uint256 wks) public {
        grant = bound(grant, 1e18, 1_000_000e18);
        pct = bound(pct, 0, FULL); // setAdditionalUnlock refuses more
        wks = bound(wks, 0, 120);

        _vest(grant);
        _setBonus(pct);
        vm.warp(block.timestamp + wks * 1 weeks);

        _sell();
        assertLe(_released(), grant, "the sell path released more than the grant");
        _claim();
        assertLe(_released(), grant, "the claim path released more than the grant");
    }

    // ── 1b. the bonus does something ────────────────────────────────────────────

    /// Everything else here bounds the bonus from some side, and a contract that never adds it at
    /// all satisfies all of those vacuously. This is the statement that it exists: at the same week
    /// a sell under a bonus releases strictly more than the schedule alone, and by exactly the
    /// bonus — which also pins the scale it is applied at.
    function testFuzz_theBonusReleasesMoreThanTheScheduleAlone(
        uint256 grant,
        uint256 pct,
        uint256 wks
    ) public {
        grant = bound(grant, 1_000e18, 1_000_000e18);
        pct = bound(pct, 1_000, 400_000); // non-zero at this grant, and clear of the ceiling
        wks = bound(wks, 0, 10);

        _vest(grant);
        vm.warp(block.timestamp + wks * 1 weeks);

        uint256 scheduleAlone = _sellable();
        _setBonus(pct);
        uint256 withBonus = _sellable();

        assertGt(withBonus, scheduleAlone, "the bonus added nothing");
        assertEq(withBonus - scheduleAlone, (grant * pct) / FULL, "and it was applied at another scale");
    }

    // ── 2. the ratchet never gives back ─────────────────────────────────────────

    /// The point of the whole construction. A holder who sold on a 30% bonus keeps it: lowering the
    /// percentage afterwards must not claw back what was already released, nor stall the schedule
    /// from there on. Reading the current percentage instead of the stored one would do both — the
    /// holder's claimed amount would sit above the recomputed unlock and pay nothing for weeks.
    function testFuzz_loweringTheBonusDoesNotClawItBack(uint256 grant, uint256 pct, uint256 wks) public {
        grant = bound(grant, 1_000e18, 1_000_000e18);
        pct = bound(pct, WEEKLY + 1, 500_000); // beats one week's unlock, stays clear of the ceiling
        wks = bound(wks, 0, 10);

        _vest(grant);
        _setBonus(pct);
        vm.warp(block.timestamp + wks * 1 weeks);
        _sell();

        uint256 releasedOnTheBonus = _released();
        assertGt(releasedOnTheBonus, 0, "nothing was sold, the case is degenerate");

        _setBonus(0); // the manager takes the bonus away
        assertEq(_released(), releasedOnTheBonus, "what was already released moved");

        // And the schedule keeps running: another week unlocks another week's worth.
        vm.warp(block.timestamp + 1 weeks);
        assertGt(_claimable(), 0, "the holder is stalled: the bonus was recomputed away");
    }

    // ── 3. the sell bonus does not leak into the ordinary claim ─────────────────

    /// claim() goes through _calculateVestingAmount(user, id) with includeCurrentBonus false, so the
    /// current percentage must be invisible to it until a sell records it. If that flag ever leaks,
    /// the bonus granted for selling is handed to everyone who simply waits.
    function testFuzz_raisingTheBonusAloneChangesNothing(uint256 grant, uint256 pct, uint256 wks) public {
        grant = bound(grant, 1e18, 1_000_000e18);
        pct = bound(pct, 1, FULL);
        wks = bound(wks, 0, 30);

        _vest(grant);
        vm.warp(block.timestamp + wks * 1 weeks);

        uint256 beforeRaise = _claimable();
        _setBonus(pct);
        assertEq(_claimable(), beforeRaise, "the sell bonus reached the ordinary claim");

        _claim();
        assertEq(_released(), beforeRaise, "and it was paid out");
    }

    // ── 4. conservation ─────────────────────────────────────────────────────────

    /// The one statement here that does not mention the formula: run the schedule out and the whole
    /// grant has been released, to the wei, whatever the percentage did on the way. A schedule that
    /// loses a little at some step passes every bound above and fails this.
    function testFuzz_theWholeGrantIsReleasedWhateverTheHistory(
        uint256 grant,
        uint256 first,
        uint256 second,
        uint256 wks
    ) public {
        grant = bound(grant, 1_000e18, 1_000_000e18);
        first = bound(first, 0, 400_000);
        second = bound(second, 0, 400_000);
        wks = bound(wks, 1, 20);

        _vest(grant);

        _setBonus(first);
        vm.warp(block.timestamp + wks * 1 weeks);
        _sell();

        _setBonus(second); // up or down, the fuzzer picks
        vm.warp(block.timestamp + wks * 1 weeks);
        _claim();

        vm.warp(block.timestamp + 60 weeks); // past vestingWeeks under any parameters
        _claim();

        assertEq(_released(), grant, "part of the grant never came out");
    }

    // ── 5. monotone in the bonus ────────────────────────────────────────────────

    /// A larger bonus never unlocks less. Measured on the sell-side view, so nothing is mutated and
    /// the two readings differ only by the percentage.
    function testFuzz_aLargerBonusNeverUnlocksLess(
        uint256 grant,
        uint256 low,
        uint256 high,
        uint256 wks
    ) public {
        grant = bound(grant, 1e18, 1_000_000e18);
        low = bound(low, 0, FULL);
        high = bound(high, low, FULL);
        wks = bound(wks, 0, 30);

        _vest(grant);
        vm.warp(block.timestamp + wks * 1 weeks);

        _setBonus(low);
        uint256 atLow = _sellable();
        _setBonus(high);
        uint256 atHigh = _sellable();

        assertGe(atHigh, atLow, "raising the bonus unlocked less");
        assertLe(atHigh, grant, "and it still cannot pass the grant");
    }

    // ── 6. no double count where the two parts meet ─────────────────────────────

    /// Late in the schedule the weekly part alone reaches the grant, and the bonus is added on top.
    /// What must bind there is the ceiling, not the sum: repeated claims may not walk the released
    /// amount past the grant one step at a time.
    function testFuzz_repeatedClaimsAtTheCeilingStayBounded(uint256 grant, uint256 pct) public {
        grant = bound(grant, 1_000e18, 1_000_000e18);
        pct = bound(pct, 0, FULL);

        _vest(grant);
        _setBonus(pct);

        for (uint256 week = 0; week < 45; week++) {
            vm.warp(block.timestamp + 1 weeks);
            if (week % 3 == 0) _sell();
            else _claim();
            assertLe(_released(), grant, "released more than the grant mid-schedule");
        }

        assertEq(_released(), grant, "and by the end the grant is fully out");
    }
}
