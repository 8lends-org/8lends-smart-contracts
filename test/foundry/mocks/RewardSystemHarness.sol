// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../../contracts/core/RewardSystem.sol";

/// @dev The cutover is fixed once, inside the upgrade. Tests need it before, after and in the
///      middle of a schedule, so the harness places it where the scenario needs it.
contract RewardSystemHarness is RewardSystem {
    function setCutover(uint256 _cutover) external {
        cutover = _cutover;
    }
}
