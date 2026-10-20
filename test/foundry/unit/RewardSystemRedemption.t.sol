// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Vesting paid in USDC at a rate fixed once, replacing the token payout.
contract RewardSystemRedemptionTest is Setup {
    uint256 pid;

    /// @dev $0.02 per token: six-decimal USDC against an eighteen-decimal token.
    uint256 constant RATE = 20_000;
    uint256 constant VESTING = 100_000e18;

    function setUp() public override {
        super.setUp();
        pid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, pid, 25_000e6, inviter);
        _seedVesting(investor, pid, VESTING);
        _fundProject(pid);
    }

    function _setRate() internal {
        vm.prank(admin);
        rewardSystem.setRedemptionRate(RATE);
    }

    // ── the rate ──

    /// @dev The rate is changeable, and a change applies to everything not yet claimed — the
    ///      watermark counts vesting units, so what is already paid is untouched.
    function test_rateCanBeChangedAndAppliesToWhatIsLeft() public {
        _setRate();
        assertEq(rewardSystem.redemptionRate(), RATE);
        vm.warp(block.timestamp + 10 weeks);

        vm.startPrank(investor);
        rewardSystem.claimVestingTokensForProject(pid);
        rewardSystem.claimVestingUsdcForProject(pid);
        vm.stopPrank();
        (, uint256 claimedAtOldRate,,,) = rewardSystem.getVestingInfoForProject(investor, pid);

        vm.prank(admin);
        rewardSystem.setRedemptionRate(RATE * 2);
        assertEq(rewardSystem.redemptionRate(), RATE * 2);

        vm.warp(block.timestamp + 10 weeks);
        (, uint256 owedUsdc) = rewardSystem.getVestingClaimable(investor, pid);
        uint256 before = usdc.balanceOf(investor);
        vm.prank(investor);
        rewardSystem.claimVestingUsdcForProject(pid);

        assertEq(usdc.balanceOf(investor) - before, owedUsdc, "paid off the new rate");
        // The watermark counts vesting units, so it advances by what the payout bought, not by what
        // it cost: at twice the rate the same money covers half as much.
        (, uint256 claimedNow,,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertEq(
            claimedNow - claimedAtOldRate,
            Math.mulDiv(owedUsdc, 1e18, RATE * 2),
            "the watermark still counts units, not money"
        );
    }

    function test_quoteFollowsTheRate() public {
        assertEq(rewardSystem.getUSDCForTokens(VESTING), 0, "no rate, no quote");
        _setRate();
        assertEq(rewardSystem.getUSDCForTokens(VESTING), VESTING * RATE / 1e18);
    }

    /// @dev The rate is a platform parameter, so the admin sets it — and neither the manager nor
    ///      the owner can any more.
    function test_rateIsAdminOnly() public {
        vm.prank(manager);
        vm.expectRevert("Not an admin");
        rewardSystem.setRedemptionRate(RATE);

        vm.prank(owner);
        vm.expectRevert("Not an admin");
        rewardSystem.setRedemptionRate(RATE);
    }

    function test_rateCannotBeZero() public {
        vm.prank(admin);
        vm.expectRevert("Invalid rate");
        rewardSystem.setRedemptionRate(0);
    }

    // ── what the claim pays ──

    function test_claimPaysUSDCAtTheRate() public {
        _setRate();
        vm.warp(block.timestamp + 10 weeks);

        (uint256 owedInTokens, uint256 owedUsdc) = rewardSystem.getVestingClaimable(investor, pid);
        assertGt(owedUsdc, 0, "nothing to claim");
        assertEq(owedInTokens, VESTING * 25_000 / BASIS_POINTS, "the first week landed on the cutover");

        uint256 usdcBefore = usdc.balanceOf(investor);
        uint256 tokensBefore = token.balanceOf(investor);

        vm.prank(investor);
        rewardSystem.claimVestingUsdcForProject(pid);

        assertEq(usdc.balanceOf(investor) - usdcBefore, owedUsdc, "paid off the rate");
        assertEq(token.balanceOf(investor), tokensBefore, "the token half is a separate call");
    }

    /// @dev The whole point of changing the currency and nothing else.
    function test_curveAndWatermarkAreUnchanged() public {
        (,, uint256 beforeRate,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        _setRate();
        (,, uint256 afterRate,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertEq(afterRate, beforeRate, "rate must not move the curve");

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 firstSlice,,) = rewardSystem.getVestingInfoForProject(investor, pid);

        vm.startPrank(investor);
        rewardSystem.claimVestingTokensForProject(pid);
        rewardSystem.claimVestingUsdcForProject(pid);
        vm.stopPrank();

        // The watermark still counts tokens, so the next slice is ten weeks of the curve — the
        // first one was larger only because week one unlocks immediately.
        vm.warp(block.timestamp + 10 weeks);
        (, uint256 claimed, uint256 secondSlice,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertEq(claimed, firstSlice, "watermark must advance by exactly what was paid");
        assertEq(secondSlice, VESTING * 10 * 25_000 / BASIS_POINTS, "second slice is not the curve's");
    }

    /// @dev There is no token payout to fall back on, so a claim before the rate is set must fail
    ///      rather than pay out at a rate of zero.
    function test_claimRevertsBeforeTheRateIsSet() public {
        vm.warp(block.timestamp + 10 weeks);

        vm.prank(investor);
        vm.expectRevert("Redemption rate not set");
        rewardSystem.claimVestingUsdcForProject(pid);
    }

    function test_claimRevertsWhenUSDCRunsShort() public {
        _setRate();
        vm.warp(block.timestamp + 40 weeks);

        // Drain what the fixture seeded, leaving the obligation unpayable.
        uint256 seeded = usdc.balanceOf(address(rewardSystem));
        vm.prank(owner);
        rewardSystem.withdraw(address(usdc), seeded, owner);

        vm.prank(investor);
        vm.expectRevert("Not enough USDC to claim");
        rewardSystem.claimVestingUsdcForProject(pid);
    }

    // ── the cutover ──

    /// @dev What unlocked before the cutover is owed in tokens, what unlocked after it in USDC, and
    ///      one curve runs across the seam.
    function test_cutoverSplitsOneCurve() public {
        uint256 t0 = block.timestamp;
        rewardSystem.setCutover(t0 + 10 weeks);
        _setRate();

        vm.warp(t0 + 20 weeks);
        (uint256 inTokens, uint256 usdcAmount) = rewardSystem.getVestingClaimable(investor, pid);
        assertEq(inTokens, VESTING * 11 * 25_000 / BASIS_POINTS, "11 weeks unlocked by the cutover");
        assertEq(usdcAmount, (VESTING * 10 * 25_000 / BASIS_POINTS) * RATE / 1e18, "the ten weeks since");

        vm.prank(investor);
        rewardSystem.claimVestingTokensForProject(pid);
        assertEq(token.balanceOf(investor), inTokens);
        assertFalse(managerRegistry.isPool(investor), "the transfer flag must not outlive the transfer");

        vm.prank(investor);
        rewardSystem.claimVestingUsdcForProject(pid);
        assertEq(usdc.balanceOf(investor), usdcAmount);
    }

    /// @dev The halves are independent: either may be taken first, or on its own.
    function test_cutoverHalvesAreIndependent() public {
        uint256 t0 = block.timestamp;
        rewardSystem.setCutover(t0 + 10 weeks);
        _setRate();
        vm.warp(t0 + 20 weeks);

        vm.prank(investor);
        rewardSystem.claimVestingUsdcForProject(pid);
        assertEq(token.balanceOf(investor), 0, "the token era is untouched");

        (uint256 stillInTokens, uint256 noUsdcLeft) = rewardSystem.getVestingClaimable(investor, pid);
        assertEq(stillInTokens, VESTING * 11 * 25_000 / BASIS_POINTS, "the whole token era is still owed");
        assertEq(noUsdcLeft, 0, "and the USDC half is spent");

        vm.prank(investor);
        rewardSystem.claimVestingTokensForProject(pid);
        assertEq(token.balanceOf(investor), stillInTokens);

        vm.prank(investor);
        vm.expectRevert("No tokens to claim");
        rewardSystem.claimVestingTokensForProject(pid);
    }

    /// @dev The token half needs no rate: only the USDC half does.
    function test_cutoverTokenHalfPaysWithoutARate() public {
        uint256 t0 = block.timestamp;
        rewardSystem.setCutover(t0 + 10 weeks);

        vm.warp(t0 + 20 weeks);
        vm.prank(investor);
        rewardSystem.claimVestingTokensForProject(pid);
        assertEq(token.balanceOf(investor), VESTING * 11 * 25_000 / BASIS_POINTS);

        vm.prank(investor);
        vm.expectRevert("Redemption rate not set");
        rewardSystem.claimVestingUsdcForProject(pid);
    }

    /// @dev An upgrade that forgot initializeCutover must not pay the token era out in USDC.
    function test_cutoverUnsetBlocksBothHalves() public {
        rewardSystem.setCutover(0);
        _setRate();
        vm.warp(block.timestamp + 10 weeks);

        vm.startPrank(investor);
        vm.expectRevert("Cutover not set");
        rewardSystem.claimVestingTokensForProject(pid);
        vm.expectRevert("Cutover not set");
        rewardSystem.claimVestingUsdcForProject(pid);
        vm.stopPrank();
    }

    /// @dev Claiming weekly must cost nothing against claiming once at the end.
    function test_frequentClaimsLoseNothingToRounding() public {
        uint256 t0 = block.timestamp;
        _setRate();

        for (uint256 w = 0; w <= 45; w++) {
            vm.warp(t0 + w * 1 weeks);
            (, uint256 due) = rewardSystem.getVestingClaimable(investor, pid);
            if (due > 0) {
                vm.prank(investor);
                rewardSystem.claimVestingUsdcForProject(pid);
            }
        }

        // Everything but the first week, which belongs to the token era.
        uint256 usdcEra = VESTING - VESTING * 25_000 / BASIS_POINTS;
        assertEq(usdc.balanceOf(investor), usdcEra * RATE / 1e18, "the whole USDC half, to the micro-dollar");
    }

    /// @dev Decided 12.10.2026: vesting credited for investments into a project the borrower never
    ///      took the money for is cancelled. Such a project is funded after the cutover, which is
    ///      what tells it apart from one already running.
    function test_vestingIsCancelledForAProjectFundedAfterTheCutover() public {
        uint256 late = _createProject(10_000e6, 50_000e6);
        _investAs(investor2, late, 25_000e6, inviter);
        _seedVesting(investor2, late, VESTING);

        // The cutover lands while the project is still collecting.
        rewardSystem.setCutover(block.timestamp);
        _setRate();

        vm.warp(block.timestamp + 1 days);
        _fundProject(late);
        vm.warp(block.timestamp + 20 weeks);

        (uint256 inTokens, uint256 usdcAmount) = rewardSystem.getVestingClaimable(investor2, late);
        assertEq(inTokens, 0);
        assertEq(usdcAmount, 0);

        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor2, late);
        assertEq(totalTokens, 0, "the display must not promise what is cancelled");

        vm.prank(investor2);
        vm.expectRevert("Vesting cancelled for this project");
        rewardSystem.claimVestingUsdcForProject(late);
    }

    /// @dev A project already funded at the cutover is untouched.
    function test_vestingSurvivesForAProjectFundedBeforeTheCutover() public {
        rewardSystem.setCutover(block.timestamp);
        _setRate();
        vm.warp(block.timestamp + 20 weeks);

        (, uint256 usdcAmount) = rewardSystem.getVestingClaimable(investor, pid);
        assertGt(usdcAmount, 0, "a running project keeps its vesting");

        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, VESTING);
    }

    /// @dev The ratchet lifts the curve at every point, the cutover included, so a position that
    ///      carries one is owed more in tokens — not just more in total.
    function test_aRatchetLiftsTheTokenEraToo() public {
        uint256 t0 = block.timestamp;
        bytes32 slot = keccak256(abi.encode(pid, keccak256(abi.encode(investor, uint256(19)))));
        vm.store(address(rewardSystem), slot, bytes32(uint256(260_000))); // 26% on top

        rewardSystem.setCutover(t0 + 10 weeks);
        _setRate();
        vm.warp(t0 + 20 weeks);

        (uint256 inTokens,) = rewardSystem.getVestingClaimable(investor, pid);
        assertEq(
            inTokens,
            VESTING * 11 * 25_000 / BASIS_POINTS + VESTING * 260_000 / BASIS_POINTS,
            "the ratchet is inside the token era"
        );
    }

    /// @dev Only the investor's vesting burns. The inviter's bonus is a lump sum gated on the
    ///      borrower having taken the money, and the cutover does not touch it.
    function test_theInviterIsPaidEvenWhenTheVestingIsCancelled() public {
        uint256 late = _createProject(10_000e6, 50_000e6);
        _investAs(investor2, late, 25_000e6, inviter);
        _seedVesting(investor2, late, VESTING);

        rewardSystem.setCutover(block.timestamp);
        _setRate();
        vm.warp(block.timestamp + 1 days);
        _fundProject(late);

        uint256 before = usdc.balanceOf(inviter);
        vm.prank(inviter);
        rewardSystem.claimUSDCForProject(late);
        assertGt(usdc.balanceOf(inviter) - before, 0, "the referral bonus is not part of the burn");
    }

    // ── the manager pays on a user's behalf ──

    function test_adminPaysBothHalves() public {
        uint256 t0 = block.timestamp;
        rewardSystem.setCutover(t0 + 10 weeks);
        _setRate();
        vm.warp(t0 + 20 weeks);

        (uint256 inTokens, uint256 usdcAmount) = rewardSystem.getVestingClaimable(investor, pid);

        vm.startPrank(admin);
        rewardSystem.sendVestingTokensForProjectToUser(investor, pid);
        rewardSystem.sendVestingUsdcForProjectToUser(investor, pid);
        vm.stopPrank();

        assertEq(token.balanceOf(investor), inTokens);
        assertEq(usdc.balanceOf(investor), usdcAmount);
    }

    /// @dev The button moves someone else's payout forward, so it sits with the admin — the
    ///      manager who used to press it cannot any more.
    function test_theSendsAreAdminOnly() public {
        _setRate();
        vm.startPrank(attacker);
        vm.expectRevert("Not an admin");
        rewardSystem.sendVestingTokensForProjectToUser(investor, pid);
        vm.expectRevert("Not an admin");
        rewardSystem.sendVestingUsdcForProjectToUser(investor, pid);
        vm.stopPrank();

        vm.startPrank(manager);
        vm.expectRevert("Not an admin");
        rewardSystem.sendVestingTokensForProjectToUser(investor, pid);
        vm.expectRevert("Not an admin");
        rewardSystem.sendVestingUsdcForProjectToUser(investor, pid);
        vm.stopPrank();
    }

    /// @dev The token batch needs no rate, and walks the projects the same way the USDC one does.
    function test_tokenBatchPaysEveryProject() public {
        uint256 second = _createProject(10_000e6, 50_000e6);
        _investAs(investor, second, 25_000e6, inviter);
        _seedVesting(investor, second, VESTING);
        _fundProject(second);

        uint256 t0 = block.timestamp;
        rewardSystem.setCutover(t0 + 10 weeks);
        vm.warp(t0 + 20 weeks);

        uint256[] memory pids = new uint256[](2);
        pids[0] = pid;
        pids[1] = second;

        vm.prank(investor);
        rewardSystem.claimVestingTokensForProjectBatch(pids);

        assertEq(token.balanceOf(investor), 2 * (VESTING * 11 * 25_000 / BASIS_POINTS), "both token eras");
    }

    // ── what the switch closes ──

    /// @dev Those who took the bonus keep the ceiling it bought them. Nothing writes the ratchet
    ///      any more, so it is planted the way the chain holds it: slot 19.
    function test_aHistoricalRatchetStillLiftsTheCurve() public {
        (,, uint256 withoutRatchet,,) = rewardSystem.getVestingInfoForProject(investor, pid);

        bytes32 slot = keccak256(abi.encode(pid, keccak256(abi.encode(investor, uint256(19)))));
        vm.store(address(rewardSystem), slot, bytes32(uint256(260_000))); // 26% on top
        assertEq(rewardSystem.userMaxAdditionalUnlockUsed(investor, pid), 260_000);

        (,, uint256 withRatchet,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertEq(withRatchet - withoutRatchet, VESTING * 260_000 / BASIS_POINTS, "26% on top of the curve");
    }

    /// @dev Payouts are USDC, so an empty token balance must not stand in the way — and `withdraw`
    ///      is free to empty it.
    function test_claimingSurvivesAnEmptyTokenBalance() public {
        _setRate();
        vm.warp(block.timestamp + 10 weeks);

        uint256 leftover = token.balanceOf(address(rewardSystem));
        vm.prank(owner);
        rewardSystem.withdraw(address(token), leftover, makeAddr("vault"));

        uint256 before = usdc.balanceOf(investor);
        vm.prank(investor);
        rewardSystem.claimVestingUsdcForProject(pid);
        assertGt(usdc.balanceOf(investor) - before, 0);
    }

    /// @dev The only batch left is all-or-nothing: one project with nothing to claim takes the whole
    ///      call down. Documented rather than fixed — the frontend has to filter the list.
    function test_theBatchRevertsOnAProjectWithNothingToClaim() public {
        _setRate();
        uint256 empty = _createProject(10_000e6, 50_000e6);
        _investAs(investor2, empty, 25_000e6, inviter);
        _fundProject(empty);
        vm.warp(block.timestamp + 10 weeks);

        uint256[] memory pids = new uint256[](2);
        pids[0] = pid;
        pids[1] = empty;

        vm.prank(investor);
        vm.expectRevert("No token rewards for this project");
        rewardSystem.claimVestingUsdcForProjectBatch(pids);
    }

    // ── getting the leftover tokens back out ──

    /// @dev Vesting is paid in USDC now, so the tokens seeded for it sit on the contract unspent.
    ///      Pulling them out is a token transfer, and it still has to pass the gate.
    function test_withdrawingTheTokenFlagsTheRecipientAndUnflagsIt() public {
        address vault = makeAddr("vault");
        assertFalse(managerRegistry.isPool(vault));

        vm.prank(owner);
        rewardSystem.withdraw(address(token), VESTING, vault);

        assertEq(token.balanceOf(vault), VESTING);
        assertFalse(managerRegistry.isPool(vault), "the flag must not outlive the transfer");
    }

    function test_withdrawingTheTokenToARealPoolLeavesItOne() public {
        assertTrue(managerRegistry.isPool(address(mockRouter)));

        vm.prank(owner);
        rewardSystem.withdraw(address(token), VESTING, address(mockRouter));

        assertTrue(managerRegistry.isPool(address(mockRouter)), "a real pool must stay one");
    }

    function test_withdrawingAnotherTokenTouchesNoFlag() public {
        address vault = makeAddr("vault");

        vm.prank(owner);
        rewardSystem.withdraw(address(usdc), 1_000e6, vault);

        assertEq(usdc.balanceOf(vault), 1_000e6);
        assertFalse(managerRegistry.isPool(vault));
    }
}
