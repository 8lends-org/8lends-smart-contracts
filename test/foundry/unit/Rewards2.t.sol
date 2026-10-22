// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract Rewards2Test is Setup {
    /// @dev $0.02 per token: six-decimal USDC against an eighteen-decimal token.
    uint256 constant RATE = 20_000;


    // ═══════════════════════════════════════════════════════════════
    //                    CREATE VESTING
    // ═══════════════════════════════════════════════════════════════

    /// @dev Checked on the contract itself: the proxy in Setup runs a harness that can still seed
    ///      vesting for the other tests.
    function test_createVesting_isGone() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        (bool ok,) = address(new Rewards2()).call(
            abi.encodeWithSignature("createVesting(address[],uint256[])", users, amounts)
        );
        assertFalse(ok, "Rewards2 must not create vesting");
    }

    // ═══════════════════════════════════════════════════════════════
    //                      CLAIM
    // ═══════════════════════════════════════════════════════════════

    function test_getUSDCForTokens_quotesTheRate() public {
        assertEq(rewards2.getUSDCForTokens(10_000e18), 0, "no rate, no quote");

        vm.prank(admin);
        rewards2.setRedemptionRate(RATE);
        assertEq(rewards2.getUSDCForTokens(10_000e18), 200e6, "$0.02 per token");
    }

    function test_claim_paysUsdcAtTheRate() public {
        _seedVesting(investor, 10_000e18);
        _fundClaims();

        vm.warp(block.timestamp + 10 weeks);

        uint256 balBefore = usdc.balanceOf(investor);
        _claimAll(investor);

        uint256 unlocked = (10_000e18 * 11 * 25_000) / 1_000_000;
        assertEq(usdc.balanceOf(investor) - balBefore, unlocked * RATE / 1e18);
        assertEq(token.balanceOf(investor), 0, "no tokens must move");
    }

    function test_claim_noVestings_reverts() public {
        vm.prank(investor);
        vm.expectRevert("No vestings found");
        rewards2.claimTokens();
    }

    /// @dev There is no token payout to fall back on, so an unset rate has to stop the claim
    ///      rather than consume the vesting and pay nothing.
    function test_claim_beforeRateIsSet_reverts() public {
        _seedVesting(investor, 10_000e18);
        vm.warp(block.timestamp + 10 weeks);

        vm.prank(investor);
        vm.expectRevert("Redemption rate not set");
        rewards2.claimUsdc();
    }

    function test_claim_usdcRunsShort_reverts() public {
        _seedVesting(investor, 10_000e18);
        vm.prank(admin);
        rewards2.setRedemptionRate(RATE);

        vm.warp(block.timestamp + 10 weeks);

        vm.prank(investor);
        vm.expectRevert("Not enough USDC to claim");
        rewards2.claimUsdc();
    }

    function test_claim_skipsDeactivated() public {
        _seedVesting(investor, 5_000e18);
        _seedVesting(investor, 3_000e18);
        _fundClaims();

        vm.prank(owner);
        rewards2.deactivateVesting(investor, 1);

        vm.warp(block.timestamp + 41 weeks);

        uint256 balBefore = usdc.balanceOf(investor);
        _claimAll(investor);

        assertEq(usdc.balanceOf(investor) - balBefore, 5_000e18 * RATE / 1e18, "only the active vesting");
    }

    function test_claim_usesClaimAddress() public {
        _seedVesting(investor, 10_000e18);
        _fundClaims();

        address altClaim = makeAddr("altClaim");
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(investor, altClaim);

        vm.warp(block.timestamp + 41 weeks);

        _claimAll(investor);

        assertEq(usdc.balanceOf(altClaim), 10_000e18 * RATE / 1e18, "USDC should go to claim address");
        assertEq(usdc.balanceOf(investor), 0, "Investor should not receive USDC");
    }

    /// @dev The ratchet lifts the curve. Nothing writes it, so it is planted the way the chain
    ///      holds it: slot 10.
    function test_claim_historicalRatchetStillLiftsTheCurve() public {
        _seedVesting(investor, 10_000e18);
        _fundClaims();

        bytes32 slot = keccak256(abi.encode(uint256(0), keccak256(abi.encode(investor, uint256(10)))));
        vm.store(address(rewards2), slot, bytes32(uint256(260_000))); // 26% on top
        assertEq(rewards2.userMaxAdditionalUnlockUsed(investor, 0), 260_000);

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 claimable,,) = rewards2.getVestingInfo(investor, 0);
        assertEq(claimable, (10_000e18 * 11 * 25_000) / 1_000_000 + 10_000e18 * 260_000 / 1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  CUTOVER: TOKENS BEFORE, USDC AFTER
    // ═══════════════════════════════════════════════════════════════

    /// @dev Up to the cutover every claim is paid in tokens.
    function test_cutover_claimBeforeItPaysTokens() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        rewards2.setCutover(t0 + 10 weeks);
        _fundClaims();
        _fundTokens();

        vm.warp(t0 + 5 weeks);
        vm.prank(investor);
        rewards2.claimTokens();

        assertEq(token.balanceOf(investor), 1_500e18, "6 weeks of 2.5%, in tokens");
        assertEq(usdc.balanceOf(investor), 0, "no USDC before the cutover");
        assertFalse(managerRegistry.isPool(investor), "the transfer flag must not outlive the transfer");
    }

    /// @dev Unlocked before the cutover but never claimed is still owed in tokens.
    function test_cutover_unclaimedBeforeItStaysTokens() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        _fundClaims();
        _fundTokens();

        vm.warp(t0 + 10 weeks);
        rewards2.setCutover(block.timestamp);

        vm.warp(t0 + 20 weeks);
        (uint256 inTokens, uint256 usdcAmount) = rewards2.getClaimable(investor);
        assertEq(inTokens, 2_750e18, "11 weeks unlocked by the cutover");
        // 21 weeks unlocked now, minus those 11: 2_500e18 at $0.02
        assertEq(usdcAmount, 50e6);

        _claimAll(investor);

        assertEq(token.balanceOf(investor), 2_750e18);
        assertEq(usdc.balanceOf(investor), 50e6);
    }

    /// @dev One curve runs across the cutover: tokens up to it, USDC after, the whole grant in total.
    function test_cutover_wholeGrantAcrossIt() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        rewards2.setCutover(t0 + 10 weeks);
        _fundClaims();
        _fundTokens();

        vm.warp(t0 + 5 weeks);
        _claimAll(investor);

        vm.warp(t0 + 41 weeks);
        _claimAll(investor);

        assertEq(token.balanceOf(investor), 2_750e18, "what had unlocked by the cutover");
        assertEq(usdc.balanceOf(investor), 7_250e18 * RATE / 1e18, "the rest at the rate");
        (, uint256 claimed,,) = rewards2.vestings(investor, 0);
        assertEq(claimed, 10_000e18, "the whole grant");
    }

    /// @dev The token part needs no rate: only the USDC part does.
    function test_cutover_tokenPartPaysWithoutARate() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        rewards2.setCutover(t0 + 10 weeks);
        _fundTokens();

        vm.warp(t0 + 5 weeks);
        _claimAll(investor);
        assertEq(token.balanceOf(investor), 1_500e18);

        // The rest of the token era still pays without a rate; only the USDC half needs one.
        vm.warp(t0 + 15 weeks);
        vm.prank(investor);
        rewards2.claimTokens();
        assertEq(token.balanceOf(investor), 2_750e18);

        vm.prank(investor);
        vm.expectRevert("Redemption rate not set");
        rewards2.claimUsdc();
    }

    function test_cutover_tokensRunShort_reverts() public {
        _seedVesting(investor, 10_000e18);
        rewards2.setCutover(block.timestamp + 10 weeks);
        _fundClaims();

        vm.warp(block.timestamp + 5 weeks);
        vm.prank(investor);
        vm.expectRevert("Not enough tokens to claim");
        rewards2.claimTokens();
    }

    /// @dev An upgrade that forgot initializeCutover must not pay the token era out in USDC.
    function test_cutover_unsetBlocksClaims() public {
        _seedVesting(investor, 10_000e18);
        _fundClaims();
        rewards2.setCutover(0);

        vm.warp(block.timestamp + 5 weeks);
        vm.prank(investor);
        vm.expectRevert("Cutover not set");
        rewards2.claimTokens();
    }

    function test_initializeCutover_ownerOnlyAndOnce() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewards2.initializeCutover();

        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        rewards2.initializeCutover();
        assertEq(rewards2.cutover(), block.timestamp);

        vm.prank(owner);
        vm.expectRevert();
        rewards2.initializeCutover();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  REDEMPTION RATE
    // ═══════════════════════════════════════════════════════════════

    function test_setRedemptionRate_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewards2.setRedemptionRate(RATE);
    }

    function test_setRedemptionRate_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert("Invalid rate");
        rewards2.setRedemptionRate(0);
    }

    /// @dev The rate is changeable, and a change applies to everything not yet claimed.
    function test_setRedemptionRate_appliesToWhatIsLeft() public {
        _seedVesting(investor, 10_000e18);
        _fundClaims();

        vm.warp(block.timestamp + 10 weeks);
        _claimAll(investor);

        vm.prank(admin);
        rewards2.setRedemptionRate(RATE * 2);

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 owed,,) = rewards2.getVestingInfo(investor, 0);
        uint256 balBefore = usdc.balanceOf(investor);
        _claimAll(investor);

        assertEq(usdc.balanceOf(investor) - balBefore, owed * RATE * 2 / 1e18, "paid off the new rate");
    }

    /// @dev The halves are independent: taking the USDC one first must not touch what the token
    ///      era still owes, and either may be left unclaimed indefinitely.
    function test_cutover_halvesAreIndependent() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        rewards2.setCutover(t0 + 10 weeks);
        _fundClaims();
        _fundTokens();

        vm.warp(t0 + 20 weeks);

        vm.prank(investor);
        rewards2.claimUsdc();
        assertEq(usdc.balanceOf(investor), 2_500e18 * RATE / 1e18, "21 weeks unlocked, minus the first 11");
        assertEq(token.balanceOf(investor), 0, "the token era is untouched");

        (uint256 stillInTokens, uint256 noUsdcLeft) = rewards2.getClaimable(investor);
        assertEq(stillInTokens, 2_750e18, "the whole token era is still owed");
        assertEq(noUsdcLeft, 0, "and the USDC half is spent");

        vm.prank(investor);
        rewards2.claimTokens();
        assertEq(token.balanceOf(investor), 2_750e18);

        // And a half that is spent stays spent.
        vm.prank(investor);
        vm.expectRevert("No tokens to claim");
        rewards2.claimTokens();
    }

    /// @dev Claiming weekly must cost nothing against claiming once at the end: what a payout
    ///      cannot round up to a whole micro-dollar stays owed and joins the next slice.
    function test_cutover_frequentClaimsLoseNothingToRounding() public {
        uint256 t0 = _now();
        _seedVesting(investor, 777_777e18 + 13); // deliberately not a round number
        _fundClaims();

        for (uint256 w = 0; w <= 45; w++) {
            vm.warp(t0 + w * 1 weeks);
            (, uint256 due) = rewards2.getClaimable(investor);
            if (due > 0) {
                vm.prank(investor);
                rewards2.claimUsdc();
            }
        }

        assertEq(usdc.balanceOf(investor), (777_777e18 + 13) * RATE / 1e18, "the whole grant, to the micro-dollar");
    }

    /// @dev A slice worth less than a micro-dollar must not be marked paid for nothing. It keeps
    ///      unlocking, so a later claim rounds to something and pays it.
    function test_cutover_aSliceTooSmallToPayIsNotConsumed() public {
        uint256 t0 = _now();
        _seedVesting(investor, 1e14); // 0.0001 of a token: a weekly slice is under one micro-dollar
        _fundClaims();

        vm.warp(t0 + 1 weeks);
        vm.prank(investor);
        vm.expectRevert("No USDC to claim");
        rewards2.claimUsdc();

        (, uint256 claimed,,) = rewards2.vestings(investor, 0);
        assertEq(claimed, 0, "nothing paid, nothing spent");

        vm.warp(t0 + 40 weeks);
        vm.prank(investor);
        rewards2.claimUsdc();
        assertGt(usdc.balanceOf(investor), 0);
    }

    /// @dev The ratchet lifts the curve at every point, the cutover included, so a vesting that
    ///      carries one is owed more in tokens — not just more in total.
    function test_cutover_ratchetLiftsTheTokenEraToo() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        bytes32 slot = keccak256(abi.encode(uint256(0), keccak256(abi.encode(investor, uint256(10)))));
        vm.store(address(rewards2), slot, bytes32(uint256(260_000))); // the 26% the bonus bought

        rewards2.setCutover(t0 + 10 weeks);
        _fundClaims();
        _fundTokens();

        vm.warp(t0 + 20 weeks);
        (uint256 inTokens, uint256 usdcAmount) = rewards2.getClaimable(investor);

        // 11 weeks of 2.5% plus the 26%, against 11 weeks alone without it.
        assertEq(inTokens, 2_750e18 + 2_600e18, "the ratchet is inside the token era");
        // The USDC half is the gap between the two points, which the ratchet shifts equally.
        assertEq(usdcAmount, 2_500e18 * RATE / 1e18, "and cancels out of the half after it");
    }

    /// @dev _unlockedAt reads the live parameters even when asked about the past, so moving them
    ///      moves where the cutover fell. Documented rather than fixed: the setter is owner-only.
    function test_cutover_changingTheCurveMovesTheSplitRetroactively() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        rewards2.setCutover(t0 + 10 weeks);
        _fundClaims();
        _fundTokens();

        vm.warp(t0 + 20 weeks);
        (uint256 before,) = rewards2.getClaimable(investor);
        assertEq(before, 2_750e18);

        vm.prank(owner);
        rewards2.setVestingParameters(50_000, 40); // 5% a week instead of 2.5%

        (uint256 afterChange,) = rewards2.getClaimable(investor);
        assertEq(afterChange, 5_500e18, "the token era doubled with the weekly rate");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    BATCH CLAIMS
    // ═══════════════════════════════════════════════════════════════

    /// @dev The owner is refused too: the button moves someone else's payout, and that is the
    ///      admin's job, not the multisig's.
    function test_claimUsdcBatch_adminOnly() public {
        address[] memory users = new address[](1);
        users[0] = investor;

        vm.prank(attacker);
        vm.expectRevert("Not an admin");
        rewards2.claimUsdcBatch(users);

        vm.prank(manager);
        vm.expectRevert("Not an admin");
        rewards2.claimUsdcBatch(users);

        vm.prank(owner);
        vm.expectRevert("Not an admin");
        rewards2.claimUsdcBatch(users);
    }

    /// @dev The batch halves are independent too, and the token one needs no rate.
    function test_claimTokensBatch_paysTheTokenEraOnly() public {
        uint256 t0 = _now();
        _seedVesting(investor, 10_000e18);
        _seedVesting(investor2, 4_000e18);
        rewards2.setCutover(t0 + 10 weeks);
        _fundTokens();

        vm.warp(t0 + 20 weeks);

        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;

        vm.prank(admin);
        rewards2.claimTokensBatch(users);

        assertEq(token.balanceOf(investor), 2_750e18);
        assertEq(token.balanceOf(investor2), 1_100e18);
        assertEq(usdc.balanceOf(investor), 0, "no rate was ever set");

        (uint256 leftTokens,) = rewards2.getClaimable(investor);
        assertEq(leftTokens, 0, "the token era is spent");
    }

    function test_claimUsdcBatch_claimsForMultipleUsers() public {
        _seedVesting(investor, 5_000e18);
        _seedVesting(investor2, 3_000e18);
        _fundClaims();

        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;

        vm.prank(admin);
        rewards2.claimUsdcBatch(users);

        assertEq(usdc.balanceOf(investor), 5_000e18 * RATE / 1e18);
        assertEq(usdc.balanceOf(investor2), 3_000e18 * RATE / 1e18);
    }

    /// @dev Without a rate nobody in the batch can be paid, so the call says so instead of
    ///      succeeding and paying no one.
    function test_claimUsdcBatch_beforeRateIsSet_reverts() public {
        _seedVesting(investor, 5_000e18);
        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](1);
        users[0] = investor;

        vm.prank(admin);
        vm.expectRevert("Redemption rate not set");
        rewards2.claimUsdcBatch(users);

        (, uint256 claimed,,) = rewards2.vestings(investor, 0);
        assertEq(claimed, 0, "a user the batch cannot pay keeps the vesting");
    }

    /// @dev A user the batch cannot pay must keep the vesting: the watermark is written only
    ///      after the money is known to be there.
    function test_claimUsdcBatch_skippedUserKeepsTheVesting() public {
        _seedVesting(investor, 5_000e18);
        _seedVesting(investor2, 3_000e18);

        vm.prank(admin);
        rewards2.setRedemptionRate(RATE);
        vm.prank(owner);
        usdc.mint(address(rewards2), 3_000e18 * RATE / 1e18); // enough for investor2 alone

        vm.warp(block.timestamp + 41 weeks);

        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;

        vm.prank(admin);
        rewards2.claimUsdcBatch(users);

        assertEq(usdc.balanceOf(investor), 0, "nothing paid");
        (, uint256 claimed,,) = rewards2.vestings(investor, 0);
        assertEq(claimed, 0, "and nothing spent");
        assertEq(usdc.balanceOf(investor2), 3_000e18 * RATE / 1e18, "the payable user still gets paid");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DEACTIVATION
    // ═══════════════════════════════════════════════════════════════

    function test_deactivateVesting_onlyOwner() public {
        _seedVesting(investor, 1000e18);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        rewards2.deactivateVesting(investor, 0);
    }

    function test_deactivateVesting_setsInactive() public {
        _seedVesting(investor, 1000e18);

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

    /// @dev Pulling the token balance out is a token transfer, and it has to pass the gate.
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
        _seedVesting(investor, 10_000e18);

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
        vm.prank(admin);
        rewards2.setRedemptionRate(RATE);
        vm.prank(owner);
        usdc.mint(address(rewards2), 1_000_000e6);
    }

    /// @dev The token era pays out of the contract's own 8LNDS.
    function _fundTokens() internal {
        vm.prank(owner);
        token.mint(address(rewards2), 1_000_000e18);
    }

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

    function _seedVesting(address user, uint256 amount) internal {
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(owner);
        rewards2.seedVestings(users, amounts);
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

        uint256 before = usdc.balanceOf(investor);
        vm.prank(admin);
        rewards2.claimUsdcBatch(users);
        assertGt(usdc.balanceOf(investor) - before, 0, "the batch at the ceiling paid nothing");

        address[] memory tooMany = new address[](ceiling + 1);
        for (uint256 i = 0; i <= ceiling; i++) tooMany[i] = address(uint160(i + 1));
        vm.prank(admin);
        vm.expectRevert("Too many users");
        rewards2.claimBatch(tooMany);
    }
}
