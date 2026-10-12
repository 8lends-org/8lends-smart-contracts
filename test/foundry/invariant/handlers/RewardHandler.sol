// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Rewards2Harness} from "../../mocks/Rewards2Harness.sol";

/// @notice Handler for Rewards2 invariant testing.
/// @dev Exercises existing vesting being claimed and deactivated in random order. Claims are paid
///      in USDC; the ghosts count vesting tokens, read from the vesting records themselves.
///      Ghost variables track cumulative state for invariant assertions.
contract RewardHandler is Test {
    Rewards2Harness public rewards2;

    address public owner;
    address[] public users;

    // ── Ghost variables ──
    uint256 public ghost_totalVested; // total tokens put into vestings
    uint256 public ghost_totalClaimed; // total tokens claimed by users

    uint256 public calls_seedVesting;
    uint256 public calls_claim;
    uint256 public calls_deactivate;

    constructor(
        Rewards2Harness _rewards2,
        address _owner,
        address[] memory _users
    ) {
        rewards2 = _rewards2;
        owner = _owner;
        users = _users;
    }

    /// @notice Seed a vesting for a random user with random amount
    function seedVesting(uint256 userIdx, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        amount = bound(amount, 100e18, 10_000e18);

        address[] memory u = new address[](1);
        u[0] = users[userIdx];
        uint256[] memory a = new uint256[](1);
        a[0] = amount;

        vm.prank(owner);
        rewards2.seedVestings(u, a);

        ghost_totalVested += amount;
        calls_seedVesting++;
    }

    /// @notice Random user claims their vesting
    function claim(uint256 userIdx) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];

        if (rewards2.userVestingCount(user) == 0) return;

        uint256 claimedBefore = _claimedOf(user);

        // Both halves, in the order the contract requires; either may have nothing owed.
        vm.prank(user);
        try rewards2.claimTokens() {
            calls_claim++;
        } catch {}
        vm.prank(user);
        try rewards2.claimUsdc() {
            calls_claim++;
        } catch {}
        ghost_totalClaimed += _claimedOf(user) - claimedBefore;
    }

    /// @notice Deactivate a random user's vesting
    function deactivate(uint256 userIdx, uint256 vestingIdx) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];

        uint256 count = rewards2.userVestingCount(user);
        if (count == 0) return;

        vestingIdx = bound(vestingIdx, 0, count - 1);

        (,,, bool isActive) = rewards2.vestings(user, vestingIdx);
        if (!isActive) return;

        vm.prank(owner);
        rewards2.deactivateVesting(user, vestingIdx);

        calls_deactivate++;
    }

    /// @notice Warp time forward (allows vesting to unlock)
    function warpWeeks(uint256 weeks_) external {
        weeks_ = bound(weeks_, 1, 5);
        vm.warp(block.timestamp + weeks_ * 1 weeks);
    }

    function _claimedOf(address user) internal view returns (uint256 claimed) {
        uint256 count = rewards2.userVestingCount(user);
        for (uint256 i = 0; i < count; i++) {
            (, uint256 claimedAmount,,) = rewards2.vestings(user, i);
            claimed += claimedAmount;
        }
    }
}
