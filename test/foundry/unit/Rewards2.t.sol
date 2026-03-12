// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract Rewards2Test is Setup {
    // ═══════════════════════════════════════════════════════════════
    //                    CREATE VESTING
    // ═══════════════════════════════════════════════════════════════

    function test_createVesting_onlyOwner() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(attacker);
        vm.expectRevert();
        rewards2.createVesting(users, amounts);
    }

    function test_createVesting_mismatchedArrays() public {
        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(owner);
        vm.expectRevert("Users and amounts length mismatch");
        rewards2.createVesting(users, amounts);
    }

    function test_createVesting_emptyArrays() public {
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(owner);
        vm.expectRevert("Empty arrays");
        rewards2.createVesting(users, amounts);
    }

    function test_createVesting_storesCorrectly() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000e18;

        vm.prank(owner);
        rewards2.createVesting(users, amounts);

        (uint256 totalAmount, uint256 claimedAmount, uint256 startTime, bool isActive) =
            rewards2.vestings(investor, 0);

        assertEq(totalAmount, 10_000e18);
        assertEq(claimedAmount, 0);
        assertEq(startTime, block.timestamp);
        assertTrue(isActive);
        assertEq(rewards2.userVestingCount(investor), 1);
        assertEq(rewards2.totalVestings(), 1);
    }

    function test_createVesting_multipleUsers() public {
        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5_000e18;
        amounts[1] = 8_000e18;

        vm.prank(owner);
        rewards2.createVesting(users, amounts);

        (uint256 amt1,,,) = rewards2.vestings(investor, 0);
        (uint256 amt2,,,) = rewards2.vestings(investor2, 0);
        assertEq(amt1, 5_000e18);
        assertEq(amt2, 8_000e18);
        assertEq(rewards2.totalVestings(), 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VESTING MATH
    // ═══════════════════════════════════════════════════════════════

    function test_vesting_immediateUnlock() public {
        _createVesting(investor, 10_000e18);

        // Week 0: 2.5% immediately (weeksUnlocked=1)
        (,, uint256 claimable,,) = rewards2.getVestingInfo(investor, 0);
        uint256 expected = (10_000e18 * 1 * 25_000) / 1_000_000; // 250e18
        assertEq(claimable, expected, "Immediate unlock should be 2.5%");
    }

    function test_vesting_after10Weeks() public {
        _createVesting(investor, 10_000e18);

        vm.warp(block.timestamp + 10 weeks);

        // weeksUnlocked = 10 + 1 = 11
        (,, uint256 claimable,,) = rewards2.getVestingInfo(investor, 0);
        uint256 expected = (10_000e18 * 11 * 25_000) / 1_000_000; // 2750e18
        assertEq(claimable, expected, "After 10 weeks: 27.5%");
    }

    function test_vesting_afterFullPeriod_getsAll() public {
        _createVesting(investor, 10_000e18);

        vm.warp(block.timestamp + 41 weeks);

        (,, uint256 claimable,,) = rewards2.getVestingInfo(investor, 0);
        assertEq(claimable, 10_000e18, "After full vesting: 100%");
    }

    // ═══════════════════════════════════════════════════════════════
    //                      CLAIM
    // ═══════════════════════════════════════════════════════════════

    function test_claim_transfersTokens() public {
        _createVesting(investor, 10_000e18);

        // Fund rewards2 with tokens
        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);

        vm.warp(block.timestamp + 10 weeks);

        uint256 balBefore = token.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();
        uint256 received = token.balanceOf(investor) - balBefore;

        uint256 expected = (10_000e18 * 11 * 25_000) / 1_000_000;
        assertEq(received, expected, "Should receive correct vested amount");
    }

    function test_claim_noVestings_reverts() public {
        vm.prank(investor);
        vm.expectRevert("No vestings found");
        rewards2.claim();
    }

    function test_claim_updatesClaimedAmount() public {
        _createVesting(investor, 10_000e18);
        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);

        vm.warp(block.timestamp + 5 weeks);

        vm.prank(investor);
        rewards2.claim();

        (, uint256 claimedAmount,,) = rewards2.vestings(investor, 0);
        uint256 expected = (10_000e18 * 6 * 25_000) / 1_000_000; // 1500e18
        assertEq(claimedAmount, expected);

        // Second claim after 5 more weeks should only give the diff
        vm.warp(block.timestamp + 5 weeks);

        uint256 balBefore = token.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();
        uint256 received = token.balanceOf(investor) - balBefore;

        // weeksUnlocked = 10+1 = 11 → totalUnlocked = 2750e18
        // already claimed 1500e18 → claimable = 1250e18
        assertEq(received, 1_250e18, "Second claim: difference only");
    }

    function test_claim_skipsDeactivated() public {
        // Create two vestings
        _createVesting(investor, 5_000e18);
        _createVesting(investor, 3_000e18);

        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);

        // Deactivate second vesting
        vm.prank(owner);
        rewards2.deactivateVesting(investor, 1);

        vm.warp(block.timestamp + 41 weeks);

        uint256 balBefore = token.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();
        uint256 received = token.balanceOf(investor) - balBefore;

        // Only first vesting (5000e18) should be claimed
        assertEq(received, 5_000e18, "Only active vesting should be claimed");
    }

    function test_claim_usesClaimAddress() public {
        _createVesting(investor, 10_000e18);
        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);

        address altClaim = makeAddr("altClaim");
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(investor, altClaim);

        vm.warp(block.timestamp + 41 weeks);

        vm.prank(investor);
        rewards2.claim();

        assertEq(token.balanceOf(altClaim), 10_000e18, "Tokens should go to claim address");
        assertEq(token.balanceOf(investor), 0, "Investor should not receive tokens");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    BATCH CLAIM
    // ═══════════════════════════════════════════════════════════════

    function test_claimBatch_managerOnly() public {
        address[] memory users = new address[](1);
        users[0] = investor;

        vm.prank(attacker);
        vm.expectRevert("Not a manager");
        rewards2.claimBatch(users);
    }

    function test_claimBatch_claimsForMultipleUsers() public {
        _createVesting(investor, 5_000e18);
        _createVesting(investor2, 3_000e18);

        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);

        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;

        vm.prank(manager);
        rewards2.claimBatch(users);

        assertEq(token.balanceOf(investor), 5_000e18);
        assertEq(token.balanceOf(investor2), 3_000e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     SELL TOKENS
    // ═══════════════════════════════════════════════════════════════

    function test_sellTokens_swapsAndSendsUSDC() public {
        // Give investor tokens
        vm.prank(owner);
        token.mint(investor, 1_000e18);

        // Investor approves rewards2
        vm.prank(investor);
        token.approve(address(rewards2), 1_000e18);

        address recipient = makeAddr("recipient");
        uint256 balBefore = usdc.balanceOf(recipient);

        vm.prank(investor);
        rewards2.sellTokens(1_000e18, recipient, 0);

        uint256 received = usdc.balanceOf(recipient) - balBefore;
        // 1000 tokens / 100 tokens_per_usdc = 10 USDC = 10e6
        assertEq(received, 10e6, "Recipient should get USDC from swap");
    }

    function test_sellTokens_zeroAmount_reverts() public {
        vm.prank(investor);
        vm.expectRevert("Invalid amount");
        rewards2.sellTokens(0, investor, 0);
    }

    function test_sellTokens_zeroRecipient_reverts() public {
        vm.prank(investor);
        vm.expectRevert("Invalid recipient");
        rewards2.sellTokens(100e18, address(0), 0);
    }

    function test_sellTokens_insufficientBalance_reverts() public {
        vm.prank(investor);
        vm.expectRevert("Not enough tokens to sell");
        rewards2.sellTokens(100e18, investor, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                   MINT REWARDS TWAP
    // ═══════════════════════════════════════════════════════════════

    function test_mintRewardsTWAP_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewards2.mintRewardsTWAP(1000e18);
    }

    function test_mintRewardsTWAP_mintsAndBuysBack() public {
        // Seed rewards2 with USDC for buyback
        vm.prank(owner);
        usdc.mint(address(rewards2), 100e6);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        rewards2.mintRewardsTWAP(1_000e18);

        // Mint + buyback:
        // 1. minted 1000e18 to rewards2 (+1000e18 supply)
        // 2. bought 1000e18 from pool (supply unchanged)
        // 3. burned 1000e18 (-1000e18 supply)
        // Net supply change: +1000e18 - 1000e18 = 0? No...
        // Step 1: supply += 1000e18
        // Step 2: swap doesn't change supply (just transfers)
        // Step 3: burn 1000e18 → supply -= 1000e18
        // Net: supply unchanged
        // But rewards2 now has 1000e18 tokens (from step 2, step 1 tokens were kept, step 3 burned 1000)
        // Actually: after step1 rewards2 has 1000e18. After step2 rewards2 has 2000e18. After step3 rewards2 has 1000e18.

        // Net: supply increased by 1000e18 (minted 1000, burned 1000, but burned from buyback not from mint)
        // Wait no. totalSupply after step1: supplyBefore + 1000e18
        // totalSupply after step2: unchanged (transfer)
        // totalSupply after step3: supplyBefore + 1000e18 - 1000e18 = supplyBefore

        // Actually burn reduces totalSupply. So net supply is unchanged.
        assertEq(token.totalSupply(), supplyBefore, "Total supply should be unchanged after mint+burn");

        // Rewards2 should now have 1000e18 tokens (net: got from buyback)
        assertEq(token.balanceOf(address(rewards2)), 1_000e18, "Rewards2 should hold minted tokens");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DEACTIVATION
    // ═══════════════════════════════════════════════════════════════

    function test_deactivateVesting_onlyOwner() public {
        _createVesting(investor, 1000e18);

        vm.prank(attacker);
        vm.expectRevert();
        rewards2.deactivateVesting(investor, 0);
    }

    function test_deactivateVesting_setsInactive() public {
        _createVesting(investor, 1000e18);

        vm.prank(owner);
        rewards2.deactivateVesting(investor, 0);

        (,,, bool isActive) = rewards2.vestings(investor, 0);
        assertFalse(isActive);
    }

    function test_deactivateVesting_invalidId_reverts() public {
        vm.prank(owner);
        vm.expectRevert("Invalid vesting ID");
        rewards2.deactivateVesting(investor, 99);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     WITHDRAW
    // ═══════════════════════════════════════════════════════════════

    function test_withdraw_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewards2.withdraw(address(usdc), 100e6, attacker);
    }

    function test_withdraw_transfersTokens() public {
        vm.prank(owner);
        usdc.mint(address(rewards2), 500e6);

        vm.prank(owner);
        rewards2.withdraw(address(usdc), 500e6, owner);

        assertEq(usdc.balanceOf(owner), 500e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  SET VESTING PARAMETERS
    // ═══════════════════════════════════════════════════════════════

    function test_setVestingParameters_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewards2.setVestingParameters(50_000, 20);
    }

    function test_setVestingParameters_updatesValues() public {
        vm.prank(owner);
        rewards2.setVestingParameters(50_000, 20);

        assertEq(rewards2.weeklyUnlock(), 50_000);
        assertEq(rewards2.vestingWeeks(), 20);
    }

    function test_setVestingParameters_invalidUnlock_reverts() public {
        vm.prank(owner);
        vm.expectRevert("Weekly unlock must be between 1000 and 1000000");
        rewards2.setVestingParameters(500, 20); // below minimum

        vm.prank(owner);
        vm.expectRevert("Weekly unlock must be between 1000 and 1000000");
        rewards2.setVestingParameters(1_000_001, 20); // above maximum
    }

    // ═══════════════════════════════════════════════════════════════
    //                     GET BALANCES
    // ═══════════════════════════════════════════════════════════════

    function test_getBalances_returnsCorrectValues() public {
        _createVesting(investor, 10_000e18);

        vm.prank(owner);
        token.mint(investor, 500e18);
        vm.prank(owner);
        usdc.mint(investor, 200e6);

        vm.warp(block.timestamp + 5 weeks);

        (uint256 tokensAll, uint256 tokensClaimable, uint256 tokensClaimed, uint256 tokensBalance, uint256 usdcBalance) =
            rewards2.getBalances(investor);

        assertEq(tokensAll, 10_000e18);
        assertEq(tokensClaimable, (10_000e18 * 6 * 25_000) / 1_000_000);
        assertEq(tokensClaimed, 0);
        assertEq(tokensBalance, 500e18);
        assertEq(usdcBalance, 200e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _createVesting(address user, uint256 amount) internal {
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(owner);
        rewards2.createVesting(users, amounts);
    }
}
