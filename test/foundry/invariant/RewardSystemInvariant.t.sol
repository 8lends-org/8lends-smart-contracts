// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import "./handlers/RewardHandler.sol";

/// @notice Invariant tests for Rewards2 vesting system
/// @dev Verifies:
///      1. Total claimed never exceeds total vested
///      2. Individual vesting claimedAmount never exceeds totalAmount
///      3. Nothing granted is stranded once the schedule has run out
contract RewardSystemInvariantTest is Setup {
    RewardHandler handler;
    address[] userList;

    function setUp() public override {
        super.setUp();

        userList = new address[](3);
        userList[0] = investor;
        userList[1] = investor2;
        userList[2] = makeAddr("investor3");

        handler = new RewardHandler(rewards2, owner, userList);

        // Without a rate and the money every claim reverts, and the handler swallows reverts, so
        // the properties below would hold over a run in which nothing was ever paid.
        vm.startPrank(owner);
        rewards2.setRedemptionRate(20_000);
        usdc.mint(address(rewards2), 1e18);
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @dev Guards the guards: a run where no claim ever went through proves nothing above.
    function afterInvariant() public view {
        assertGt(handler.calls_claim(), 0, "no claim succeeded during the run");
    }

    /// @notice Total tokens claimed never exceeds total tokens vested
    function invariant_noOverClaim() public view {
        assertLe(
            handler.ghost_totalClaimed(),
            handler.ghost_totalVested(),
            "INVARIANT VIOLATED: claimed > vested"
        );
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
