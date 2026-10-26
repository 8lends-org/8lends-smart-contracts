// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {MockOracle} from "../../../contracts/mocks/MockOracle.sol";

contract RewardSystemTest is Setup {
    uint256 pid;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);
    }

    /// @dev Vesting is redeemed for USDC at $0.02, so a claim needs the rate written first.
    function _setRate() internal {
        vm.prank(admin);
        rewardSystem.setRedemptionRate(20_000);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  recordInvestment
    // ═══════════════════════════════════════════════════════════════

    function test_recordInvestment_accruesNoTokenRewards() public {
        _investAs(investor, pid, 25_000e6, inviter);

        (,uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, 0, "Token cashback is off: investing must not accrue tokens");
    }

    function test_recordInvestment_calculatesReferralRewards() public {
        _investAs(investor, pid, 25_000e6, inviter);

        // referralPercentage = 6% → inviter gets 1500 USDC
        (uint256 inviterUSDC,,,,) = rewardSystem.getProjectRewards(inviter, pid);
        assertEq(inviterUSDC, 1_500e6, "Inviter USDC reward incorrect");
    }


    // ═══════════════════════════════════════════════════════════════
    //        ORACLE FAILURE BLOCKS INVEST
    // ═══════════════════════════════════════════════════════════════


    // ═══════════════════════════════════════════════════════════════
    //                      VESTING SCHEDULE
    // ═══════════════════════════════════════════════════════════════

    function test_vesting_firstWeekImmediateUnlock() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid); // activates vesting

        // Week 0: 2.5% immediately unlocked (weeksPassed=0, weeksUnlocked=1)
        (,, uint256 claimable,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        (,uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);

        // 2.5% = 25000/1000000
        uint256 expected = (totalTokens * 1 * 25_000) / 1_000_000;
        assertEq(claimable, expected, "Week 0 should unlock 2.5%");
    }

    function test_vesting_afterFullPeriod_getsAll() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        // Warp 40+ weeks
        vm.warp(block.timestamp + 41 weeks);

        (,, uint256 claimable,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        (,uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);

        assertEq(claimable, totalTokens, "After full vesting, should get all tokens");
    }


    // ═══════════════════════════════════════════════════════════════
    //              USDC REWARD CLAIMS
    // ═══════════════════════════════════════════════════════════════

    function test_claimUSDC_transfersRewards() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        // Inviter has USDC rewards
        uint256 balBefore = usdc.balanceOf(inviter);
        vm.prank(inviter);
        rewardSystem.claimUSDCForProject(pid);
        uint256 received = usdc.balanceOf(inviter) - balBefore;

        // 6% of 25,000 = 1,500 USDC
        assertEq(received, 1_500e6, "Inviter should receive 6% referral");
    }

    function test_claimUSDC_zeroesOutBalance() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        vm.prank(inviter);
        rewardSystem.claimUSDCForProject(pid);

        // Second claim should fail
        vm.prank(inviter);
        vm.expectRevert("No USDC rewards for this project");
        rewardSystem.claimUSDCForProject(pid);
    }

    // ═══════════════════════════════════════════════════════════════
    //          VULNERABILITY #7: POOL STATUS TOGGLE
    // ═══════════════════════════════════════════════════════════════

    /// @dev 8LNDS reaches a wallet only through the flag, and the flag must not outlive the
    ///      transfer. The token era of a vesting claim is where that still happens.
    function test_poolStatusToggle_onATokenClaim() public {
        rewardSystem.setCutover(block.timestamp + 10 weeks);
        _investAs(investor, pid, 25_000e6, inviter);
        _seedVesting(investor, pid, 150_000e18);
        _fundProject(pid);

        vm.warp(block.timestamp + 5 weeks);
        assertFalse(managerRegistry.pools(investor));

        vm.prank(investor);
        rewardSystem.claimVestingTokensForProject(pid);

        assertGt(token.balanceOf(investor), 0, "nothing moved, the case is degenerate");
        assertFalse(managerRegistry.pools(investor), "the flag must not outlive the transfer");
    }

    // ═══════════════════════════════════════════════════════════════
    //                   BATCH OPERATIONS
    // ═══════════════════════════════════════════════════════════════

    function test_claimTokensBatch_multipleProjects() public {
        uint256 pid2 = _createProject(10_000e6, 30_000e6);

        _investAs(investor, pid, 25_000e6, inviter);
        _investAs(investor, pid2, 15_000e6, inviter);
        _seedVesting(investor, pid, 150_000e18);
        _seedVesting(investor, pid2, 90_000e18);

        _fundProject(pid);
        _fundProject(pid2);

        vm.warp(block.timestamp + 5 weeks);

        uint256[] memory pids = new uint256[](2);
        pids[0] = pid;
        pids[1] = pid2;

        _setRate();
        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        rewardSystem.claimVestingUsdcForProjectBatch(pids);

        assertGt(usdc.balanceOf(investor) - balBefore, 0, "Should receive USDC from both projects");
        assertEq(token.balanceOf(investor), 0, "no tokens must move");
    }

    // ═══════════════════════════════════════════════════════════════
    //                  seeding vesting is gone
    // ═══════════════════════════════════════════════════════════════

    /// @dev Checked on the contract itself: the proxy in Setup runs a harness that can still seed
    ///      vesting for the other tests. Nothing in RewardSystem creates a position any more —
    ///      token cashback is off and the manual distribution went with it, so the contract only
    ///      pays out what was granted before the upgrade.
    function test_distributeVestingTokens_isGone() public {
        address[] memory u = new address[](1);
        u[0] = investor;
        uint256[] memory a = new uint256[](1);
        a[0] = 1_000e18;
        uint256[] memory p = new uint256[](1);
        p[0] = pid;

        (bool ok,) = address(new RewardSystem()).call(
            abi.encodeWithSignature("distributeVestingTokens(address[],uint256[],uint256[])", u, a, p)
        );
        assertFalse(ok, "RewardSystem must not create vesting");
    }

    // ═══════════════════════════════════════════════════════════════
    //                  PARAMETER VALIDATION
    // ═══════════════════════════════════════════════════════════════

    /// @dev Neither the manager nor the owner can set them.
    function test_setParameters_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert("Not an admin");
        rewardSystem.setParameters(60_000);

        vm.prank(manager);
        vm.expectRevert("Not an admin");
        rewardSystem.setParameters(60_000);

        vm.prank(owner);
        vm.expectRevert("Not an admin");
        rewardSystem.setParameters(60_000);
    }

    function test_claimBeforeActivation_reverts() public {
        // Invest but don't fund (no activation)
        _investAs(investor, pid, 25_000e6, inviter);

        vm.prank(investor);
        vm.expectRevert("Project rewards not activated");
        rewardSystem.claimVestingUsdcForProject(pid);
    }

    // ── boundaries ──────────────────────────────────────────────────────────────

    /// @dev Every percentage band in setParameters is inclusive at both ends. Checked on the
    ///      referral percentage, the one band the narrowed setter still carries.
    function test_setParameters_acceptsBothEndsOfTheReferralBand() public {
        vm.startPrank(admin);
        rewardSystem.setParameters(1_000);
        assertEq(rewardSystem.referralPercentage(), 1_000, "the lower end was refused");

        rewardSystem.setParameters(70_000);
        assertEq(rewardSystem.referralPercentage(), 70_000, "the upper end was refused");

        vm.expectRevert("Referral percentage out of range");
        rewardSystem.setParameters(999);
        vm.expectRevert("Referral percentage out of range");
        rewardSystem.setParameters(70_001);
        vm.stopPrank();
    }

    /// @dev The curve has no setter at all now: `_unlockedAt` reads it for past moments too, so a
    ///      change would re-split an already-earned book between tokens and USDC. What is left in
    ///      `setParameters` is the referral, a price on new investments.
    function test_setParameters_cannotReachTheCurve() public {
        uint256 weeksBefore = rewardSystem.vestingWeeks();
        uint256 unlockBefore = rewardSystem.weeklyUnlock();

        vm.prank(admin);
        rewardSystem.setParameters(50_000);

        assertEq(rewardSystem.referralPercentage(), 50_000, "the referral is still a dial");
        assertEq(rewardSystem.vestingWeeks(), weeksBefore, "the curve did not move");
        assertEq(rewardSystem.weeklyUnlock(), unlockBefore, "the curve did not move");
    }

    /// @dev An empty batch is refused rather than quietly doing nothing — whoever passed the
    ///      wrong slice should hear about it.
    function test_sendUSDCForProjectToUserBatch_refusesEmptyArrays() public {
        vm.prank(admin);
        vm.expectRevert("Empty arrays");
        rewardSystem.sendUSDCForProjectToUserBatch(new address[](0), new uint256[](0));
    }

    /// @dev claimUSDCForProjectBatch had no test at all: its loop walks the caller's project ids
    ///      and pays each. One id is enough to make the walk observable.
    function test_claimUSDCForProjectBatch_paysEachProject() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        uint256[] memory pids = new uint256[](1);
        pids[0] = pid;

        uint256 before = usdc.balanceOf(inviter);
        vm.prank(inviter);
        rewardSystem.claimUSDCForProjectBatch(pids);

        assertGt(usdc.balanceOf(inviter) - before, 0, "the batch claim paid nothing");
    }

    /// @dev The project-count ceiling is inclusive, on the view the rewards screen reads. Asked
    ///      about the inviter: token cashback is off, so the investor's own side is always zero
    ///      and would pass the assertion without the ceiling working at all.
    function test_getProjectsRewardsTotal_acceptsExactlyTheCeiling() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        uint256[] memory atCeiling = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) atCeiling[i] = pid;
        (uint256 totalUSDC,,,) = rewardSystem.getProjectsRewardsTotal(inviter, atCeiling);
        assertGt(totalUSDC, 0, "the ceiling-sized request returned nothing");

        uint256[] memory tooMany = new uint256[](501);
        for (uint256 i = 0; i < 501; i++) tooMany[i] = pid;
        vm.expectRevert("Too many projects");
        rewardSystem.getProjectsRewardsTotal(inviter, tooMany);
    }
}
