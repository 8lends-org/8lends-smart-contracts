// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

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
        vm.prank(owner);
        rewardSystem.setRedemptionRate(RATE);
    }

    // ── the rate ──

    /// @dev The rate is changeable, and a change applies to everything not yet claimed — the
    ///      watermark counts vesting units, so what is already paid is untouched.
    function test_rateCanBeChangedAndAppliesToWhatIsLeft() public {
        _setRate();
        assertEq(rewardSystem.redemptionRate(), RATE);
        vm.warp(block.timestamp + 10 weeks);

        vm.prank(investor);
        rewardSystem.claimTokensForProject(pid);
        (, uint256 claimedAtOldRate,,,) = rewardSystem.getVestingInfoForProject(investor, pid);

        vm.prank(owner);
        rewardSystem.setRedemptionRate(RATE * 2);
        assertEq(rewardSystem.redemptionRate(), RATE * 2);

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 owed,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        uint256 before = usdc.balanceOf(investor);
        vm.prank(investor);
        rewardSystem.claimTokensForProject(pid);

        assertEq(usdc.balanceOf(investor) - before, owed * RATE * 2 / 1e18, "paid off the new rate");
        (, uint256 claimedNow,,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertEq(claimedNow - claimedAtOldRate, owed, "the watermark still counts units, not money");
    }

    function test_rateIsOwnerOnly() public {
        vm.prank(manager);
        vm.expectRevert();
        rewardSystem.setRedemptionRate(RATE);
    }

    function test_rateCannotBeZero() public {
        vm.prank(owner);
        vm.expectRevert("Invalid rate");
        rewardSystem.setRedemptionRate(0);
    }

    // ── what the claim pays ──

    function test_claimPaysUSDCAtTheRate() public {
        _setRate();
        vm.warp(block.timestamp + 10 weeks);

        (,, uint256 owedTokens,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertGt(owedTokens, 0, "nothing to claim");

        uint256 usdcBefore = usdc.balanceOf(investor);
        uint256 tokensBefore = token.balanceOf(investor);

        vm.prank(investor);
        rewardSystem.claimTokensForProject(pid);

        assertEq(usdc.balanceOf(investor) - usdcBefore, owedTokens * RATE / 1e18, "paid off the rate");
        assertEq(token.balanceOf(investor), tokensBefore, "no tokens must move");
    }

    /// @dev The whole point of changing the currency and nothing else.
    function test_curveAndWatermarkAreUnchanged() public {
        (,, uint256 beforeRate,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        _setRate();
        (,, uint256 afterRate,,) = rewardSystem.getVestingInfoForProject(investor, pid);
        assertEq(afterRate, beforeRate, "rate must not move the curve");

        vm.warp(block.timestamp + 10 weeks);
        (,, uint256 firstSlice,,) = rewardSystem.getVestingInfoForProject(investor, pid);

        vm.prank(investor);
        rewardSystem.claimTokensForProject(pid);

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
        rewardSystem.claimTokensForProject(pid);
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
        rewardSystem.claimTokensForProject(pid);
    }

    // ── what the switch closes ──

    /// @dev Those who took the bonus keep the ceiling it bought them. Nothing writes the ratchet
    ///      any more, so it is planted the way the chain holds it: slot 19.
    function test_aHistoricalRatchetStillLiftsTheCurve() public {
        (,, uint256 withoutRatchet,,) = rewardSystem.getVestingInfoForProject(investor, pid);

        bytes32 slot = keccak256(abi.encode(pid, keccak256(abi.encode(investor, uint256(19)))));
        vm.store(address(rewardSystem), slot, bytes32(uint256(260_000))); // the very 26%
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
        rewardSystem.claimTokensForProject(pid);
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
        rewardSystem.claimTokensForProjectBatch(pids);
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
