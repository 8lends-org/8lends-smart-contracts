// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import "./handlers/RewardHandler.sol";

/// @notice Invariant tests for Rewards2 vesting system
/// @dev Verifies:
///      1. Total claimed never exceeds total vested
///      2. Token balance of rewards2 is always sufficient for remaining obligations
///      3. Individual vesting claimedAmount never exceeds totalAmount
contract RewardSystemInvariantTest is Setup {
    RewardHandler handler;
    address[] userList;

    function setUp() public override {
        super.setUp();

        userList = new address[](3);
        userList[0] = investor;
        userList[1] = investor2;
        userList[2] = makeAddr("investor3");

        handler = new RewardHandler(
            rewards2,
            token,
            usdc,
            owner,
            userList
        );

        targetContract(address(handler));
    }

    /// @notice Total tokens claimed never exceeds total tokens vested
    function invariant_noOverClaim() public view {
        assertLe(
            handler.ghost_totalClaimed(),
            handler.ghost_totalVested(),
            "INVARIANT VIOLATED: claimed > vested"
        );
    }

    /// @notice Rewards2 token balance >= remaining claimable obligations
    /// @dev remaining = totalVested - totalClaimed - totalDeactivated
    function invariant_tokenSolvency() public view {
        uint256 totalVested = handler.ghost_totalVested();
        uint256 totalClaimed = handler.ghost_totalClaimed();
        uint256 totalDeactivated = handler.ghost_totalDeactivated();

        // Remaining obligations (what could still be claimed)
        uint256 remaining = 0;
        if (totalVested > totalClaimed + totalDeactivated) {
            remaining = totalVested - totalClaimed - totalDeactivated;
        }

        uint256 balance = token.balanceOf(address(rewards2));
        assertGe(balance, remaining, "INVARIANT VIOLATED: rewards2 token balance < remaining obligations");
    }

    /// @notice Everything granted stays reachable: taken plus still claimable is the whole grant
    ///         once the schedule has run out.
    /// @dev Every other property here bounds payouts from above; this is the one that bounds them
    ///      from below, so a schedule losing a little each week cannot pass.
    function invariant_nothingIsStrandedAfterTheSchedule() public {
        vm.warp(block.timestamp + 60 weeks);

        for (uint256 i = 0; i < userList.length; i++) {
            (uint256 all, uint256 claimable, uint256 claimed, , ) = rewards2.getBalances(userList[i]);
            if (all == 0) continue;
            assertEq(claimed + claimable, all, "INVARIANT VIOLATED: part of a grant reaches nobody");
        }
    }

    /// @notice Each user's claimedAmount never exceeds their totalAmount
    function invariant_individualVestingBounds() public view {
        for (uint256 i = 0; i < userList.length; i++) {
            uint256 count = rewards2.userVestingCount(userList[i]);
            for (uint256 j = 0; j < count; j++) {
                (uint256 totalAmount, uint256 claimedAmount,,) = rewards2.vestings(userList[i], j);
                assertLe(
                    claimedAmount,
                    totalAmount,
                    "INVARIANT VIOLATED: individual claimedAmount > totalAmount"
                );
            }
        }
    }
}
