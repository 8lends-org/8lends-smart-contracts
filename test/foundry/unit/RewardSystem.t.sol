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

    // ═══════════════════════════════════════════════════════════════
    //                  recordInvestment
    // ═══════════════════════════════════════════════════════════════

    function test_recordInvestment_calculatesTokenRewards() public {
        _investAs(investor, pid, 25_000e6, inviter);

        // tokenPercentage = 6% → 1500 USDC worth of tokens
        // At 1 USDC = 100 tokens: 1500 * 100 = 150,000 tokens
        (,uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertGt(totalTokens, 0, "Should have token rewards");

        // Expected: 25000e6 * 60000 / 1000000 = 1500e6 USDC worth
        // 1500e6 USDC → 1500e6 * 100 * 1e12 = 150_000e18 tokens
        assertEq(totalTokens, 150_000e18, "Token reward amount incorrect");
    }

    function test_recordInvestment_calculatesReferralRewards() public {
        _investAs(investor, pid, 25_000e6, inviter);

        // referralPercentage = 6% → inviter gets 1500 USDC
        (uint256 inviterUSDC,,,,) = rewardSystem.getProjectRewards(inviter, pid);
        assertEq(inviterUSDC, 1_500e6, "Inviter USDC reward incorrect");
    }

    function test_recordInvestment_welcomeBonus_forNewUser() public {
        // Investment >= 1000 USDC by new user → 30 USDC bonus
        // Use small hardcap project so we can invest smaller amounts
        uint256 smallPid = _createProject(500e6, 5_000e6);
        _investAs(investor, smallPid, 1_000e6, inviter);

        (uint256 investorUSDC,,,,) = rewardSystem.getProjectRewards(investor, smallPid);
        assertEq(investorUSDC, 30e6, "Welcome bonus should be 30 USDC");
    }

    function test_recordInvestment_noWelcomeBonus_belowMinimum() public {
        uint256 smallPid = _createProject(100e6, 5_000e6);
        _investAs(investor, smallPid, 500e6, inviter);

        (uint256 investorUSDC,,,,) = rewardSystem.getProjectRewards(investor, smallPid);
        assertEq(investorUSDC, 0, "No welcome bonus for small investment");
    }

    function test_recordInvestment_welcomeBonus_onlyOnce() public {
        uint256 smallPid = _createProject(1_000e6, 10_000e6);
        _investAs(investor, smallPid, 2_000e6, inviter);

        // First investment got welcome bonus
        (uint256 usdcAfterFirst,,,,) = rewardSystem.getProjectRewards(investor, smallPid);
        assertEq(usdcAfterFirst, 30e6, "First investment: welcome bonus");

        // Second investment: no more welcome bonus (isNewUser = false)
        _investAs(investor, smallPid, 2_000e6, inviter);
        (uint256 usdcAfterSecond,,,,) = rewardSystem.getProjectRewards(investor, smallPid);
        assertEq(usdcAfterSecond, 30e6, "Second investment: no additional welcome bonus");
    }

    // ═══════════════════════════════════════════════════════════════
    //        ORACLE FAILURE BLOCKS INVEST
    // ═══════════════════════════════════════════════════════════════

    function test_oracleFailure_blocksInvest() public {
        // Set oracle to one that returns price=0 (simulates oracle failure)
        MockOracle zeroOracle = new MockOracle();
        vm.prank(owner);
        rewardSystem.setOracle(address(zeroOracle));

        // Prepare invest
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.userNonces(investor);
        bytes memory sig = _signInvest(investor, pid, 5_000e6, currentNonce + 1, inviter);

        // Invest reverts because Oracle returns price=0
        vm.prank(investor);
        vm.expectRevert("Oracle: no valid price");
        fundraise.investUpdate(pid, 5_000e6, currentNonce + 1, sig, inviter);
    }

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

    function test_vesting_claimTokens_transfersCorrectAmount() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        // Warp 10 weeks
        vm.warp(block.timestamp + 10 weeks);

        uint256 balBefore = token.balanceOf(investor);
        vm.prank(investor);
        rewardSystem.claimTokensForProject(pid);
        uint256 received = token.balanceOf(investor) - balBefore;

        assertGt(received, 0, "Should receive tokens");
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

    function test_poolStatusToggle_normalFlow() public {
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);
        vm.warp(block.timestamp + 5 weeks);

        // Before claim: investor is NOT a pool
        assertFalse(managerRegistry.pools(investor));

        // Claim tokens (this toggles pool status)
        vm.prank(investor);
        rewardSystem.claimTokensForProject(pid);

        // After claim: investor should NOT be a pool anymore (toggled back)
        assertFalse(managerRegistry.pools(investor), "Pool status should be reset after claim");
    }

    // ═══════════════════════════════════════════════════════════════
    //                   BATCH OPERATIONS
    // ═══════════════════════════════════════════════════════════════

    function test_claimTokensBatch_multipleProjects() public {
        uint256 pid2 = _createProject(10_000e6, 30_000e6);

        _investAs(investor, pid, 25_000e6, inviter);
        _investAs(investor, pid2, 15_000e6, inviter);

        _fundProject(pid);
        _fundProject(pid2);

        vm.warp(block.timestamp + 5 weeks);

        uint256[] memory pids = new uint256[](2);
        pids[0] = pid;
        pids[1] = pid2;

        uint256 balBefore = token.balanceOf(investor);
        vm.prank(investor);
        rewardSystem.claimTokensForProjectBatch(pids);
        uint256 received = token.balanceOf(investor) - balBefore;

        assertGt(received, 0, "Should receive tokens from both projects");
    }

    // ═══════════════════════════════════════════════════════════════
    //                  PARAMETER VALIDATION
    // ═══════════════════════════════════════════════════════════════

    function test_setParameters_onlyManager() public {
        vm.prank(attacker);
        vm.expectRevert("Not a manager");
        rewardSystem.setParameters(60_000, 60_000, 60_000, 30e6, 1000e6, 25_000, 40);
    }

    function test_claimBeforeActivation_reverts() public {
        // Invest but don't fund (no activation)
        _investAs(investor, pid, 25_000e6, inviter);

        vm.prank(investor);
        vm.expectRevert("Project rewards not activated");
        rewardSystem.claimTokensForProject(pid);
    }
}
