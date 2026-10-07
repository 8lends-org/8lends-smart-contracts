// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract Rewards2Test is Setup {
    /// @dev $0.02 per token: six-decimal USDC against an eighteen-decimal token.
    uint256 constant RATE = 20_000;


    // ═══════════════════════════════════════════════════════════════
    //                    CREATE VESTING
    // ═══════════════════════════════════════════════════════════════

    function test_createVesting_onlyOwner() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
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
    //                      CLAIM
    // ═══════════════════════════════════════════════════════════════

    function test_claim_paysUsdcAtTheRate() public {
        _createVesting(investor, 10_000e18);
        _fundClaims();

        vm.warp(block.timestamp + 10 weeks);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();

        uint256 unlocked = (10_000e18 * 11 * 25_000) / 1_000_000;
        assertEq(usdc.balanceOf(investor) - balBefore, unlocked * RATE / 1e18);
        assertEq(token.balanceOf(investor), 0, "no tokens must move");
    }

    function test_claim_noVestings_reverts() public {
        vm.prank(investor);
        vm.expectRevert("No vestings found");
        rewards2.claim();
    }

    /// @dev There is no token payout to fall back on, so an unset rate has to stop the claim
    ///      rather than consume the vesting and pay nothing.
    function test_claim_beforeRateIsSet_reverts() public {
        _createVesting(investor, 10_000e18);
        vm.warp(block.timestamp + 10 weeks);

        vm.prank(investor);
        vm.expectRevert("Redemption rate not set");
        rewards2.claim();
    }

    function test_claim_usdcRunsShort_reverts() public {
        _createVesting(investor, 10_000e18);
        vm.prank(owner);
        rewards2.setRedemptionRate(RATE);

        vm.warp(block.timestamp + 10 weeks);

        vm.prank(investor);
        vm.expectRevert("Not enough USDC to claim");
        rewards2.claim();
    }

    function test_claim_updatesClaimedAmount() public {
        _createVesting(investor, 10_000e18);
        _fundClaims();

        vm.warp(block.timestamp + 5 weeks);

        vm.prank(investor);
        rewards2.claim();

        (, uint256 claimedAmount,,) = rewards2.vestings(investor, 0);
        uint256 expected = (10_000e18 * 6 * 25_000) / 1_000_000; // 1500e18
        assertEq(claimedAmount, expected, "the watermark counts tokens, not money");

        // Second claim after 5 more weeks should only give the diff
        vm.warp(block.timestamp + 5 weeks);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();

        // weeksUnlocked = 10+1 = 11 → totalUnlocked = 2750e18, already claimed 1500e18
        assertEq(usdc.balanceOf(investor) - balBefore, 1_250e18 * RATE / 1e18);
    }

    function test_claim_skipsDeactivated() public {
        _createVesting(investor, 5_000e18);
        _createVesting(investor, 3_000e18);
        _fundClaims();

        vm.prank(owner);
        rewards2.deactivateVesting(investor, 1);

        vm.warp(block.timestamp + 41 weeks);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();

        assertEq(usdc.balanceOf(investor) - balBefore, 5_000e18 * RATE / 1e18, "only the active vesting");
    }

    function test_claim_usesClaimAddress() public {
        _createVesting(investor, 10_000e18);
        _fundClaims();

        address altClaim = makeAddr("altClaim");
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(investor, altClaim);

        vm.warp(block.timestamp + 41 weeks);

        vm.prank(investor);
        rewards2.claim();

        assertEq(usdc.balanceOf(altClaim), 10_000e18 * RATE / 1e18, "USDC should go to claim address");
        assertEq(usdc.balanceOf(investor), 0, "Investor should not receive USDC");
    }

    /// @dev A ratchet raised before the bonus was withdrawn still lifts the curve. Nothing writes
    ///      it any more, so it is planted the way the chain holds it: slot 10.
    function test_claim_historicalRatchetStillLiftsTheCurve() public {
        _createVesting(investor, 10_000e18);
        _fundClaims();

        bytes32 slot = keccak256(abi.encode(uint256(0), keccak256(abi.encode(investor, uint256(10)))));
        vm.store(address(rewards2), slot, bytes32(uint256(260_000))); // 26% on top
        assertEq(rewards2.userMaxAdditionalUnlockUsed(investor, 0), 260_000);

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 claimable,,) = rewards2.getVestingInfo(investor, 0);
        assertEq(claimable, (10_000e18 * 11 * 25_000) / 1_000_000 + 10_000e18 * 260_000 / 1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  REDEMPTION RATE
    // ═══════════════════════════════════════════════════════════════

    function test_setRedemptionRate_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewards2.setRedemptionRate(RATE);
    }

    function test_setRedemptionRate_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert("Invalid rate");
        rewards2.setRedemptionRate(0);
    }

    /// @dev The rate is changeable, and a change applies to everything not yet claimed.
    function test_setRedemptionRate_appliesToWhatIsLeft() public {
        _createVesting(investor, 10_000e18);
        _fundClaims();

        vm.warp(block.timestamp + 10 weeks);
        vm.prank(investor);
        rewards2.claim();

        vm.prank(owner);
        rewards2.setRedemptionRate(RATE * 2);

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 owed,,) = rewards2.getVestingInfo(investor, 0);
        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        rewards2.claim();

        assertEq(usdc.balanceOf(investor) - balBefore, owed * RATE * 2 / 1e18, "paid off the new rate");
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
        _fundClaims();

        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;

        vm.prank(manager);
        rewards2.claimBatch(users);

        assertEq(usdc.balanceOf(investor), 5_000e18 * RATE / 1e18);
        assertEq(usdc.balanceOf(investor2), 3_000e18 * RATE / 1e18);
    }

    function test_claimBatch_beforeRateIsSet_reverts() public {
        _createVesting(investor, 5_000e18);
        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](1);
        users[0] = investor;

        vm.prank(manager);
        vm.expectRevert("Redemption rate not set");
        rewards2.claimBatch(users);
    }

    /// @dev A user the batch cannot pay must keep the vesting: the watermark is written only
    ///      after the money is known to be there.
    function test_claimBatch_skippedUserKeepsTheVesting() public {
        _createVesting(investor, 5_000e18);
        _createVesting(investor2, 3_000e18);

        vm.startPrank(owner);
        rewards2.setRedemptionRate(RATE);
        usdc.mint(address(rewards2), 3_000e18 * RATE / 1e18); // enough for investor2 alone
        vm.stopPrank();

        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;

        vm.prank(manager);
        rewards2.claimBatch(users);

        assertEq(usdc.balanceOf(investor), 0, "nothing paid");
        (, uint256 claimed,,) = rewards2.vestings(investor, 0);
        assertEq(claimed, 0, "and nothing spent");
        assertEq(usdc.balanceOf(investor2), 3_000e18 * RATE / 1e18, "the payable user still gets paid");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DEACTIVATION
    // ═══════════════════════════════════════════════════════════════

    function test_deactivateVesting_onlyOwner() public {
        _createVesting(investor, 1000e18);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
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
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        rewards2.withdraw(address(usdc), 100e6, attacker);
    }

    function test_withdraw_otherToken_touchesNoFlag() public {
        vm.prank(owner);
        usdc.mint(address(rewards2), 500e6);

        address vault = makeAddr("vault");
        vm.prank(owner);
        rewards2.withdraw(address(usdc), 500e6, vault);

        assertEq(usdc.balanceOf(vault), 500e6);
        assertFalse(managerRegistry.isPool(vault));
    }

    /// @dev Nothing moves the token any more, so its balance is a leftover to be pulled out.
    ///      That is still a token transfer, and it still has to pass the gate.
    function test_withdraw_token_flagsTheRecipientAndUnflagsIt() public {
        vm.prank(owner);
        token.mint(address(rewards2), 1_000e18);

        address vault = makeAddr("vault");
        assertFalse(managerRegistry.isPool(vault));

        vm.prank(owner);
        rewards2.withdraw(address(token), 1_000e18, vault);

        assertEq(token.balanceOf(vault), 1_000e18);
        assertFalse(managerRegistry.isPool(vault), "the flag must not outlive the transfer");
    }

    function test_withdraw_tokenToARealPool_leavesItOne() public {
        vm.prank(owner);
        token.mint(address(rewards2), 1_000e18);
        assertTrue(managerRegistry.isPool(address(mockRouter)));

        vm.prank(owner);
        rewards2.withdraw(address(token), 1_000e18, address(mockRouter));

        assertTrue(managerRegistry.isPool(address(mockRouter)), "a real pool must stay one");
    }

    // ═══════════════════════════════════════════════════════════════
    //                  SET VESTING PARAMETERS
    // ═══════════════════════════════════════════════════════════════

    function test_setVestingParameters_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
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

    /// @dev Vesting is paid in USDC, so a claim needs both the rate and the money.
    function _fundClaims() internal {
        vm.startPrank(owner);
        rewards2.setRedemptionRate(RATE);
        usdc.mint(address(rewards2), 1_000_000e6);
        vm.stopPrank();
    }

    function _createVesting(address user, uint256 amount) internal {
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(owner);
        rewards2.createVesting(users, amounts);
    }

    // ── boundaries ──────────────────────────────────────────────────────────────

    /// @dev Both ends of the weekly-unlock band are legal values, and only outside them does the
    ///      setter refuse. The band is inclusive on purpose: 0.1% a week is a real schedule.
    function test_setVestingParameters_acceptsBothEndsOfTheBand() public {
        vm.startPrank(owner);
        rewards2.setVestingParameters(1_000, 40);
        assertEq(rewards2.weeklyUnlock(), 1_000, "the lower end was refused");

        rewards2.setVestingParameters(1_000_000, 40);
        assertEq(rewards2.weeklyUnlock(), 1_000_000, "the upper end was refused");

        vm.expectRevert("Weekly unlock must be between 1000 and 1000000");
        rewards2.setVestingParameters(999, 40);
        vm.expectRevert("Weekly unlock must be between 1000 and 1000000");
        rewards2.setVestingParameters(1_000_001, 40);
        vm.stopPrank();
    }

    /// @dev A zero in the amounts array is refused for its own entry, not swallowed as a vesting
    ///      that can never release anything.
    function test_createVesting_refusesAZeroAmount() public {
        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 0;

        vm.prank(owner);
        vm.expectRevert("Invalid amount");
        rewards2.createVesting(users, amounts);

        assertEq(rewards2.userVestingCount(investor), 0, "the first entry was written anyway");
    }

    /// @dev The batch ceiling is inclusive: exactly the limit goes through, one past it does not.
    function test_createVesting_acceptsExactlyTheBatchCeiling() public {
        uint256 ceiling = 2_000;
        address[] memory users = new address[](ceiling);
        uint256[] memory amounts = new uint256[](ceiling);
        for (uint256 i = 0; i < ceiling; i++) {
            users[i] = address(uint160(i + 1));
            amounts[i] = 1e18;
        }

        vm.prank(owner);
        rewards2.createVesting(users, amounts);
        assertEq(rewards2.userVestingCount(users[ceiling - 1]), 1, "the last of the batch was dropped");

        address[] memory tooMany = new address[](ceiling + 1);
        uint256[] memory tooManyAmounts = new uint256[](ceiling + 1);
        for (uint256 i = 0; i <= ceiling; i++) {
            tooMany[i] = address(uint160(i + 1));
            tooManyAmounts[i] = 1e18;
        }
        vm.prank(owner);
        vm.expectRevert("Too many users");
        rewards2.createVesting(tooMany, tooManyAmounts);
    }

    /// @dev getVestingsInfo is the view the front end lists a holder's grants with, and nothing
    ///      called it. Its arrays are sized from the count, so an index walked one too far is a
    ///      panic rather than a wrong number.
    function test_getVestingsInfo_listsEveryGrant() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.startPrank(owner);
        rewards2.createVesting(users, amounts);
        rewards2.createVesting(users, amounts);
        vm.stopPrank();

        (
            uint256[] memory ids,
            uint256[] memory totals,
            ,
            ,
            uint256[] memory startTimes,
            bool[] memory active
        ) = rewards2.getVestingsInfo(investor);

        assertEq(ids.length, 2, "both grants should be listed");
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
        assertEq(totals[0], 500e18);
        assertEq(totals[1], 500e18);
        assertGt(startTimes[0], 0);
        assertTrue(active[0] && active[1]);
    }
    /// @dev claimBatch carries its own ceiling, separate from the one on createVesting above, and
    ///      it is inclusive too. A batch of exactly the limit pays whoever in it has something.
    function test_claimBatch_acceptsExactlyTheCeiling() public {
        uint256 ceiling = 2_000;
        _createVesting(investor, 10_000e18);
        vm.prank(owner);
        token.mint(address(rewards2), 10_000e18);
        vm.warp(block.timestamp + 10 weeks);

        address[] memory users = new address[](ceiling);
        users[0] = investor;
        for (uint256 i = 1; i < ceiling; i++) users[i] = address(uint160(i + 1));

        uint256 before = token.balanceOf(investor);
        vm.prank(manager);
        rewards2.claimBatch(users);
        assertGt(token.balanceOf(investor) - before, 0, "the batch at the ceiling paid nothing");

        address[] memory tooMany = new address[](ceiling + 1);
        for (uint256 i = 0; i <= ceiling; i++) tooMany[i] = address(uint160(i + 1));
        vm.prank(manager);
        vm.expectRevert("Too many users");
        rewards2.claimBatch(tooMany);
    }
}
