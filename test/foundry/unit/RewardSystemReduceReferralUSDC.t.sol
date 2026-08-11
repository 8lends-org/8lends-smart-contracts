// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Tests for RewardSystem.reduceReferralUSDC — EL-1529 out-of-window cancellation.
/// @dev The function subtracts a specified `reduction` from projectReferrals[inviter][pid].totalRewardsUSDC
///      using OPTIMISTIC CONCURRENCY CONTROL:
///        * current == expected → subtract `reduction` (happy path)
///        * current  > expected → subtract only `reduction`, preserving the growth (new legit safe)
///        * current  < expected → skip (claim or previous batch already reduced)
///
///      Additional safety: reduction is capped at current to prevent underflow.
///      Only owner. Emits ReferralUSDCReduced per changed bucket.
contract RewardSystemReduceReferralUSDCTest is Setup {
    // 6% referral bonus on a 25,000 USDC investment = 1,500 USDC
    uint256 constant INVEST_AMOUNT = 25_000e6;
    uint256 constant REFERRAL_BONUS = 1_500e6;

    uint256 pid;
    uint256 pid2;
    address inviter2;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);
        pid2 = _createProject(20_000e6, 40_000e6);
        inviter2 = makeAddr("inviter2");
    }

    function _refUSDC(address _inviter, uint256 _pid) internal view returns (uint256) {
        (uint256 totalUSDC,,,,) = rewardSystem.getProjectRewards(_inviter, _pid);
        return totalUSDC;
    }

    function _refTokens(address _user, uint256 _pid) internal view returns (uint256) {
        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(_user, _pid);
        return totalTokens;
    }

    /// @notice Helper: build a single-entry batch with (inviter, pid, reduction, expected).
    function _oneEntryBatch(
        address _inviter,
        uint256 _pid,
        uint256 _reduction,
        uint256 _expected
    ) internal pure returns (
        address[] memory inviters,
        uint256[] memory pids,
        uint256[] memory reductions,
        uint256[] memory expected
    ) {
        inviters = new address[](1);
        pids = new uint256[](1);
        reductions = new uint256[](1);
        expected = new uint256[](1);
        inviters[0] = _inviter;
        pids[0] = _pid;
        reductions[0] = _reduction;
        expected[0] = _expected;
    }

    // ═══════════════════════════════════════════════════════════════
    //   CASE A: current == expected → subtract exactly `reduction`
    // ═══════════════════════════════════════════════════════════════

    function test_caseA_matchesSnapshot_subtractsExactly() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        assertEq(_refUSDC(inviter, pid), REFERRAL_BONUS, "seed");

        // Subtract 1476 (out-of-window portion), keeping 24 (legit)
        uint256 reduction = 1_476e6;
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, REFERRAL_BONUS);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RewardSystem.ReferralUSDCReduced(inviter, pid, REFERRAL_BONUS, REFERRAL_BONUS - reduction);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), 24e6, "24 USDC legit remains");
    }

    function test_caseA_fullZeroOut() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);

        // Subtract the entire bonus
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, REFERRAL_BONUS, REFERRAL_BONUS);

        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), 0, "bucket zeroed");
    }

    // ═══════════════════════════════════════════════════════════════
    //  CASE B: current > expected → subtract only `reduction`,
    //           preserving the growth (new legit invests untouched)
    // ═══════════════════════════════════════════════════════════════

    function test_caseB_bucketGrewSinceSnapshot_preservesNewLegit() public {
        // Simulate the M-1 race scenario:
        // - Snapshot at T0: bucket = 1500 (24 legit + 1476 out-of-window)
        // - Operator prepares batch: reduction=1476, expected=1500
        // - Between T0 and T2: new legit +30 arrives → bucket = 1530
        // - Execution at T2: reduce by 1476, expect 54 remains (24 old + 30 new)

        _investAs(investor, pid, INVEST_AMOUNT, inviter); // + 1500 to inviter
        assertEq(_refUSDC(inviter, pid), REFERRAL_BONUS, "seed 1500");

        // Simulate "+30 new legit" arriving between snapshot and execution:
        // Do another invest by a different investor pointing to the SAME inviter.
        // (Same investor cannot have two inviters.)
        address newReferee = makeAddr("newReferee");
        _investAs(newReferee, pid, 500e6, inviter); // 500 * 6% = 30 USDC bonus
        uint256 currentAfterGrowth = _refUSDC(inviter, pid);
        assertEq(currentAfterGrowth, REFERRAL_BONUS + 30e6, "bucket grew by 30");

        // Operator's batch still targets the OLD snapshot (1500) with reduction 1476
        uint256 reduction = 1_476e6;
        uint256 snapshotExpected = REFERRAL_BONUS; // 1500 at T0
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, snapshotExpected);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RewardSystem.ReferralUSDCReduced(inviter, pid, currentAfterGrowth, currentAfterGrowth - reduction);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        // Growth preserved: 24 old legit + 30 new legit = 54 USDC
        assertEq(_refUSDC(inviter, pid), 24e6 + 30e6, "growth (30 new legit) preserved");
    }

    // ═══════════════════════════════════════════════════════════════
    //  CASE C: current < expected → SKIP entirely
    //          (claim happened, or previous batch already reduced)
    // ═══════════════════════════════════════════════════════════════

    function test_caseC_claimHappenedBefore_skips() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        _fundProject(pid); // activate rewards so claim works

        // Inviter claims — bucket becomes 0
        vm.prank(inviter);
        rewardSystem.claimUSDCForProject(pid);
        assertEq(_refUSDC(inviter, pid), 0, "claim zeroed bucket");

        // Operator's stale batch: still expects 1500, reduction 1476
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, 1_476e6, REFERRAL_BONUS);

        vm.recordLogs();
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        // Skip: no state change, no event
        assertEq(_refUSDC(inviter, pid), 0, "bucket stays 0 (not re-credited, not underflowed)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReferralUSDCReduced(address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], sig, "no event when case C skip");
        }
    }

    function test_caseC_previousBatchReduced_skipsSecondBatch() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);

        // First batch: reduce 1476 out of 1500 → bucket becomes 24
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, 1_476e6, REFERRAL_BONUS);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);
        assertEq(_refUSDC(inviter, pid), 24e6, "first batch reduced to 24");

        // Second batch (stale — still thinks bucket is 1500) tries the same reduction.
        // MUST be skipped, not accidentally destroy the 24 legit remainder.
        vm.recordLogs();
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), 24e6, "legit remainder preserved after stale re-run");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReferralUSDCReduced(address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], sig, "no event on second stale batch");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //   ZERO-REDUCTION: distinct code path from Case C skip
    // ═══════════════════════════════════════════════════════════════

    function test_zeroReduction_isNoOp() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, 0, REFERRAL_BONUS);

        vm.recordLogs();
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), REFERRAL_BONUS, "zero reduction = no state change");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReferralUSDCReduced(address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], sig, "no event when reduction is 0");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //   SAFETY: reduction > current → cap at current, no underflow
    // ═══════════════════════════════════════════════════════════════

    function test_safety_reductionExceedsCurrent_cappedAtCurrent() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);

        // Reduction way bigger than the bucket
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, type(uint256).max, REFERRAL_BONUS);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RewardSystem.ReferralUSDCReduced(inviter, pid, REFERRAL_BONUS, 0);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), 0, "capped: bucket zeroed, no underflow");
    }

    // ═══════════════════════════════════════════════════════════════
    //          BATCH: multiple buckets in one transaction
    // ═══════════════════════════════════════════════════════════════

    function test_batch_mixedCases_ABC() public {
        // Build a batch that exercises all three cases in one call.
        // Use a large-hardCap project so multiple invests fit.
        uint256 pidBig = _createProject(20_000e6, 100_000e6);

        // Bucket A: exactly matches snapshot → case A
        _investAs(investor, pidBig, INVEST_AMOUNT, inviter);

        // Bucket B: will grow by +30 between snapshot and execution → case B
        address inviterB = makeAddr("inviterB");
        address investorB = makeAddr("investorB");
        _investAs(investorB, pidBig, INVEST_AMOUNT, inviterB);
        uint256 snapshotB = _refUSDC(inviterB, pidBig); // 1500

        // Bucket C: will shrink to 0 (claim) before execution → case C
        address inviterC = makeAddr("inviterC");
        uint256 pidC = _createProject(20_000e6, 40_000e6);
        address investorC = makeAddr("investorC");
        _investAs(investorC, pidC, INVEST_AMOUNT, inviterC);
        _fundProject(pidC);
        uint256 snapshotC = _refUSDC(inviterC, pidC); // 1500

        // Simulate concurrent changes AFTER snapshot:
        // B grows by +30 legit
        address newRefereeB = makeAddr("newRefereeB");
        _investAs(newRefereeB, pidBig, 500e6, inviterB); // + 30 to inviterB
        assertEq(_refUSDC(inviterB, pidBig), snapshotB + 30e6, "B grew by 30");

        // C is claimed (bucket → 0)
        vm.prank(inviterC);
        rewardSystem.claimUSDCForProject(pidC);
        assertEq(_refUSDC(inviterC, pidC), 0, "C claimed");

        // Build combined batch with SNAPSHOT expected values (stale)
        address[] memory inviters = new address[](3);
        uint256[] memory pids = new uint256[](3);
        uint256[] memory reductions = new uint256[](3);
        uint256[] memory expected = new uint256[](3);

        inviters[0] = inviter;    pids[0] = pidBig; reductions[0] = 1_476e6; expected[0] = REFERRAL_BONUS;  // Case A
        inviters[1] = inviterB;   pids[1] = pidBig; reductions[1] = 1_476e6; expected[1] = snapshotB;       // Case B
        inviters[2] = inviterC;   pids[2] = pidC;   reductions[2] = 1_476e6; expected[2] = snapshotC;       // Case C

        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inviters, pids, reductions, expected);

        // Verify each case handled correctly
        assertEq(_refUSDC(inviter, pidBig), 24e6, "A: reduced 1500 -> 24 (case A)");
        assertEq(_refUSDC(inviterB, pidBig), 24e6 + 30e6, "B: reduced 1530 -> 54, preserving new legit (case B)");
        assertEq(_refUSDC(inviterC, pidC), 0, "C: stays 0, skipped (case C)");
    }

    // ═══════════════════════════════════════════════════════════════
    //          ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════

    function test_revertsIfNonOwner() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, 100e6, REFERRAL_BONUS);

        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        vm.prank(manager);
        vm.expectRevert();
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);
    }

    // ═══════════════════════════════════════════════════════════════
    //          INPUT VALIDATION
    // ═══════════════════════════════════════════════════════════════

    function test_revertsIfLengthMismatch_usersVsPids() public {
        address[] memory inviters = new address[](2);
        uint256[] memory pids = new uint256[](1);
        uint256[] memory reductions = new uint256[](2);
        uint256[] memory expected = new uint256[](2);
        inviters[0] = inviter; inviters[1] = inviter2;
        pids[0] = pid;

        vm.prank(owner);
        vm.expectRevert("Users and projectIds length mismatch");
        rewardSystem.reduceReferralUSDC(inviters, pids, reductions, expected);
    }

    function test_revertsIfLengthMismatch_usersVsReductions() public {
        address[] memory inviters = new address[](2);
        uint256[] memory pids = new uint256[](2);
        uint256[] memory reductions = new uint256[](1);
        uint256[] memory expected = new uint256[](2);

        vm.prank(owner);
        vm.expectRevert("Users and reductions length mismatch");
        rewardSystem.reduceReferralUSDC(inviters, pids, reductions, expected);
    }

    function test_revertsIfLengthMismatch_usersVsExpected() public {
        address[] memory inviters = new address[](2);
        uint256[] memory pids = new uint256[](2);
        uint256[] memory reductions = new uint256[](2);
        uint256[] memory expected = new uint256[](1);

        vm.prank(owner);
        vm.expectRevert("Users and expected length mismatch");
        rewardSystem.reduceReferralUSDC(inviters, pids, reductions, expected);
    }

    function test_revertsIfBatchTooLarge() public {
        address[] memory inviters = new address[](501);
        uint256[] memory pids = new uint256[](501);
        uint256[] memory reductions = new uint256[](501);
        uint256[] memory expected = new uint256[](501);
        for (uint256 i = 0; i < 501; i++) {
            inviters[i] = inviter;
        }

        vm.prank(owner);
        vm.expectRevert("Batch too large");
        rewardSystem.reduceReferralUSDC(inviters, pids, reductions, expected);
    }

    // address(0) inviters are no longer explicitly rejected — they become a silent no-op
    // because their bucket is always 0 (either Case C skip if expected > 0, or capped
    // reduction hits the reduction==0 skip). This test locks in that behaviour.
    function test_zeroInviterIsSilentNoOp() public {
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(address(0), pid, 100e6, 0);

        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        (uint256 usdcAfter,,) = rewardSystem.projectReferrals(address(0), pid);
        assertEq(usdcAfter, 0, "address(0) bucket must remain 0");
    }

    // ═══════════════════════════════════════════════════════════════
    //     BEHAVIOUR: claim after reduce
    // ═══════════════════════════════════════════════════════════════

    function test_afterReduce_zeroedBucketRevertsOnClaim() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        _fundProject(pid);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, REFERRAL_BONUS, REFERRAL_BONUS);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        vm.prank(inviter);
        vm.expectRevert("No USDC rewards for this project");
        rewardSystem.claimUSDCForProject(pid);
    }

    function test_afterReduce_partialBucketPaysRemainder() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        _fundProject(pid);

        // Reduce by 1300, keeping 200 as legitimate remainder
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, 1_300e6, REFERRAL_BONUS);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);
        assertEq(_refUSDC(inviter, pid), 200e6);

        uint256 balBefore = usdc.balanceOf(inviter);
        vm.prank(inviter);
        rewardSystem.claimUSDCForProject(pid);
        assertEq(usdc.balanceOf(inviter) - balBefore, 200e6, "claim pays remainder only");
    }

    // ═══════════════════════════════════════════════════════════════
    //     ISOLATION
    // ═══════════════════════════════════════════════════════════════

    function test_doesNotAffectOtherBuckets() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        _investAs(investor2, pid2, INVEST_AMOUNT, inviter2);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, REFERRAL_BONUS, REFERRAL_BONUS);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), 0, "target zeroed");
        assertEq(_refUSDC(inviter2, pid2), REFERRAL_BONUS, "other untouched");
    }

    function test_doesNotAffectTokenVesting() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        uint256 tokensBefore = _refTokens(investor, pid);
        assertGt(tokensBefore, 0);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, REFERRAL_BONUS, REFERRAL_BONUS);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refTokens(investor, pid), tokensBefore, "vesting untouched");
    }

    function test_doesNotAffectSameInviterDifferentProject() public {
        _investAs(investor, pid, INVEST_AMOUNT, inviter);
        _investAs(investor, pid2, INVEST_AMOUNT, inviter);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, REFERRAL_BONUS, REFERRAL_BONUS);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), 0);
        assertEq(_refUSDC(inviter, pid2), REFERRAL_BONUS);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Core safety invariant: after any OCC-based reduction call, bucket value
    ///      is monotonically non-increasing, regardless of inputs.
    function testFuzz_cannotIncreaseInvariant(
        uint256 investAmount,
        uint256 reduction,
        uint256 expected
    ) public {
        investAmount = bound(investAmount, 100e6, 30_000e6);
        _investAs(investor, pid, investAmount, inviter);
        uint256 before = _refUSDC(inviter, pid);
        assertGt(before, 0);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, expected);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        uint256 finalValue = _refUSDC(inviter, pid);
        assertLe(finalValue, before, "invariant: cannot increase");
    }

    /// @dev Case C invariant: if current < expected, bucket MUST be unchanged.
    function testFuzz_caseC_currentBelowExpected_skips(uint256 investAmount, uint256 reduction) public {
        investAmount = bound(investAmount, 100e6, 30_000e6);
        _investAs(investor, pid, investAmount, inviter);
        uint256 currentBefore = _refUSDC(inviter, pid);

        // Force case C: expected > current
        uint256 expected = currentBefore + 1;

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, expected);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid), currentBefore, "case C: bucket unchanged");
    }

    /// @dev Case A invariant: current == expected → bucket = current - min(reduction, current).
    function testFuzz_caseA_matchesSnapshot(uint256 investAmount, uint256 reduction) public {
        investAmount = bound(investAmount, 100e6, 30_000e6);
        _investAs(investor, pid, investAmount, inviter);
        uint256 currentBefore = _refUSDC(inviter, pid);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, currentBefore); // expected == current

        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        uint256 expectedFinal = reduction >= currentBefore ? 0 : currentBefore - reduction;
        assertEq(_refUSDC(inviter, pid), expectedFinal, "case A: exact reduction applied (capped)");
    }

    /// @dev Case B invariant: current > expected → bucket = current - min(reduction, current).
    ///      Same delta applied as in Case A — growth is preserved because we don't try to
    ///      "match" the expected snapshot value, only apply the intended reduction.
    function testFuzz_caseB_bucketGrewSinceSnapshot(
        uint256 investAmount,
        uint256 growthAmount,
        uint256 reduction
    ) public {
        investAmount = bound(investAmount, 100e6, 20_000e6); // leave room for growth
        growthAmount = bound(growthAmount, 100e6, 10_000e6);

        _investAs(investor, pid, investAmount, inviter);
        uint256 snapshotValue = _refUSDC(inviter, pid);

        // Simulate growth: another invest by a different investor pointing to same inviter
        address newInvestor = makeAddr("newInvestor_fuzz");
        _investAs(newInvestor, pid, growthAmount, inviter);
        uint256 currentAfterGrowth = _refUSDC(inviter, pid);
        assertGt(currentAfterGrowth, snapshotValue, "growth applied");

        // Operator's batch uses OLD snapshot value
        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, snapshotValue);

        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        // Growth (currentAfterGrowth - snapshotValue) is preserved
        uint256 effectiveReduction = reduction >= currentAfterGrowth ? currentAfterGrowth : reduction;
        uint256 expectedFinal = currentAfterGrowth - effectiveReduction;

        assertEq(_refUSDC(inviter, pid), expectedFinal, "case B: growth preserved");

        // Growth preservation property: if reduction was capped or exact,
        // the growth portion should be intact whenever reduction <= snapshot.
        if (reduction <= snapshotValue) {
            uint256 preserved = _refUSDC(inviter, pid);
            assertGe(preserved, currentAfterGrowth - snapshotValue,
                "growth (>= newly added) preserved when reduction <= snapshot");
        }
    }

    /// @dev Batch isolation: bucket B is unchanged regardless of what happens to bucket A.
    function testFuzz_batchIsolation(uint256 investA, uint256 investB, uint256 reductionA, uint256 expectedA) public {
        uint256 pidBig = _createProject(20_000e6, 100_000e6);
        investA = bound(investA, 100e6, 30_000e6);
        investB = bound(investB, 100e6, 30_000e6);

        address inviterA = inviter;
        address inviterB = inviter2;
        address investorB = makeAddr("investorB_fuzz");

        _investAs(investor, pidBig, investA, inviterA);
        _investAs(investorB, pidBig, investB, inviterB);

        uint256 beforeA = _refUSDC(inviterA, pidBig);
        uint256 beforeB = _refUSDC(inviterB, pidBig);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviterA, pidBig, reductionA, expectedA);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertLe(_refUSDC(inviterA, pidBig), beforeA, "A cannot grow");
        assertEq(_refUSDC(inviterB, pidBig), beforeB, "B is isolated from A");
    }

    /// @dev projectId keying isolation: reducing (inviter, pidX) never affects (inviter, pidY).
    function testFuzz_projectIdIsolation(
        uint256 amount1,
        uint256 amount2,
        uint256 reduction1,
        uint256 expected1
    ) public {
        amount1 = bound(amount1, 100e6, 30_000e6);
        amount2 = bound(amount2, 100e6, 30_000e6);

        _investAs(investor, pid, amount1, inviter);
        _investAs(investor2, pid2, amount2, inviter);

        uint256 before2 = _refUSDC(inviter, pid2);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction1, expected1);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refUSDC(inviter, pid2), before2, "pid2 bucket untouched");
    }

    /// @dev Event field correctness: emitted (oldAmount, newAmount) match state before/after.
    function testFuzz_eventFieldsMatchStateChange(
        uint256 investAmount,
        uint256 reduction,
        uint256 expected
    ) public {
        investAmount = bound(investAmount, 100e6, 30_000e6);
        _investAs(investor, pid, investAmount, inviter);
        uint256 currentBefore = _refUSDC(inviter, pid);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, expected);

        vm.recordLogs();
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ReferralUSDCReduced(address,uint256,uint256,uint256)");
        uint256 eventCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            eventCount++;

            (uint256 oldAmt, uint256 newAmt) =
                abi.decode(logs[i].data, (uint256, uint256));

            assertEq(oldAmt, currentBefore, "event: oldAmount == current before");
            assertEq(newAmt, _refUSDC(inviter, pid), "event: newAmount matches post-state");
        }

        // Event emission rule: emitted iff state actually changed
        uint256 postState = _refUSDC(inviter, pid);
        if (postState != currentBefore) {
            assertEq(eventCount, 1, "one event when state changed");
        } else {
            assertEq(eventCount, 0, "no event when state unchanged");
        }
    }

    /// @dev Token vesting is never touched, regardless of inputs.
    function testFuzz_doesNotTouchTokenVesting(
        uint256 investAmount,
        uint256 reduction,
        uint256 expected
    ) public {
        investAmount = bound(investAmount, 100e6, 30_000e6);
        _investAs(investor, pid, investAmount, inviter);

        uint256 investorTokensBefore = _refTokens(investor, pid);
        uint256 inviterTokensBefore = _refTokens(inviter, pid);

        (address[] memory inv, uint256[] memory ps, uint256[] memory red, uint256[] memory exp) =
            _oneEntryBatch(inviter, pid, reduction, expected);
        vm.prank(owner);
        rewardSystem.reduceReferralUSDC(inv, ps, red, exp);

        assertEq(_refTokens(investor, pid), investorTokensBefore, "investor tokens untouched");
        assertEq(_refTokens(inviter, pid), inviterTokensBefore, "inviter tokens untouched");
    }
}
