// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../../contracts/Rewards2.sol";
import "../../../../contracts/Token.sol";
import "../../mocks/MockUSDC.sol";

/// @notice Handler for Rewards2 invariant testing.
/// @dev Exercises vesting creation, claims, and deactivation in random order.
///      Ghost variables track cumulative state for invariant assertions.
contract RewardHandler is Test {
    Rewards2 public rewards2;
    Token public token;
    MockUSDC public usdc;

    address public owner;
    address[] public users;

    // ── Ghost variables ──
    uint256 public ghost_totalVested; // total tokens put into vestings
    uint256 public ghost_totalClaimed; // total tokens claimed by users
    uint256 public ghost_totalDeactivated; // total tokens in deactivated vestings

    uint256 public calls_createVesting;
    uint256 public calls_claim;
    uint256 public calls_deactivate;

    constructor(
        Rewards2 _rewards2,
        Token _token,
        MockUSDC _usdc,
        address _owner,
        address[] memory _users
    ) {
        rewards2 = _rewards2;
        token = _token;
        usdc = _usdc;
        owner = _owner;
        users = _users;
    }

    /// @notice Create a vesting for a random user with random amount
    function createVesting(uint256 userIdx, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        amount = bound(amount, 100e18, 10_000e18);

        address[] memory u = new address[](1);
        u[0] = users[userIdx];
        uint256[] memory a = new uint256[](1);
        a[0] = amount;

        // Mint tokens to rewards2 to cover this vesting
        vm.prank(owner);
        token.mint(address(rewards2), amount);

        vm.prank(owner);
        rewards2.createVesting(u, a);

        ghost_totalVested += amount;
        calls_createVesting++;
    }

    /// @notice Random user claims their vesting
    function claim(uint256 userIdx) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];

        if (rewards2.userVestingCount(user) == 0) return;

        uint256 balBefore = token.balanceOf(user);

        vm.prank(user);
        try rewards2.claim() {
            uint256 claimed = token.balanceOf(user) - balBefore;
            ghost_totalClaimed += claimed;
            calls_claim++;
        } catch {
            // claim can revert if nothing to claim
        }
    }

    /// @notice Deactivate a random user's vesting
    function deactivate(uint256 userIdx, uint256 vestingIdx) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];

        uint256 count = rewards2.userVestingCount(user);
        if (count == 0) return;

        vestingIdx = bound(vestingIdx, 0, count - 1);

        (uint256 totalAmount, uint256 claimedAmount,, bool isActive) = rewards2.vestings(user, vestingIdx);
        if (!isActive) return;

        vm.prank(owner);
        rewards2.deactivateVesting(user, vestingIdx);

        ghost_totalDeactivated += (totalAmount - claimedAmount);
        calls_deactivate++;
    }

    /// @notice Warp time forward (allows vesting to unlock)
    function warpWeeks(uint256 weeks_) external {
        weeks_ = bound(weeks_, 1, 5);
        vm.warp(block.timestamp + weeks_ * 1 weeks);
    }
}
