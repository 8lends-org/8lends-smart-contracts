// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Fundraise} from "../../../contracts/core/Fundraise.sol";
import {Market} from "../../../contracts/core/market/Market.sol";

/// @notice Pins the compatibility version of every contract that has one.
/// @dev The point of this file is to fail. Moving a number here is a breaking change, and the only
///      way to make it pass again is to edit the expectation deliberately — by which time whoever
///      did it has had to think about who else speaks to the contract. An upgrade that breaks
///      nobody should never reach this test.
contract ContractVersionTest is Test {
    function test_fundraiseVersionIsPinned() public {
        assertEq(new Fundraise().version(), 1, "Fundraise: announce the break before moving this");
    }

    function test_marketVersionIsPinned() public {
        assertEq(new Market().version(), 1, "Market: announce the break before moving this");
    }
}
