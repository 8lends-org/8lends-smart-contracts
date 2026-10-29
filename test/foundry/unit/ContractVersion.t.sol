// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Fundraise} from "../../../contracts/core/Fundraise.sol";
import {Market} from "../../../contracts/core/market/Market.sol";
import {RewardSystem} from "../../../contracts/core/RewardSystem.sol";
import {Rewards2} from "../../../contracts/core/Rewards2.sol";
import {Buyback} from "../../../contracts/core/Buyback.sol";

/// @notice Pins the compatibility version of every contract that has one.
/// @dev The point of this file is to fail. Moving a number here is a breaking change, and the only
///      way to make it pass again is to edit the expectation deliberately — by which time whoever
///      did it has had to think about who else speaks to the contract.
contract ContractVersionTest is Test {
    function test_fundraiseVersionIsPinned() public {
        assertEq(new Fundraise().version(), 2, "Fundraise: announce the break before moving this");
    }

    function test_marketVersionIsPinned() public {
        assertEq(new Market().version(), 1, "Market: announce the break before moving this");
    }

    function test_rewardSystemVersionIsPinned() public {
        assertEq(new RewardSystem().version(), 1, "RewardSystem: announce the break before moving this");
    }

    function test_rewards2VersionIsPinned() public {
        assertEq(new Rewards2().version(), 1, "Rewards2: announce the break before moving this");
    }

    function test_buybackVersionIsPinned() public {
        assertEq(new Buyback().version(), 1, "Buyback: announce the break before moving this");
    }
}
