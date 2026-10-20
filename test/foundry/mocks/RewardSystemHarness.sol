// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../../contracts/core/RewardSystem.sol";

/// @dev The cutover is fixed once, inside the upgrade. Tests need it before, after and in the
///      middle of a schedule, so the harness places it where the scenario needs it.
///
///      RewardSystem cannot create vesting, only pay it out, so tests seed the state here.
contract RewardSystemHarness is RewardSystem {
    function setCutover(uint256 _cutover) external {
        cutover = _cutover;
    }

    function seedVestings(
        address[] calldata _users,
        uint256[] calldata _amounts,
        uint256[] calldata _projectIds
    ) external {
        require(_users.length == _amounts.length, "Users and amounts length mismatch");
        require(_users.length == _projectIds.length, "Users and projectIds length mismatch");
        for (uint256 i = 0; i < _users.length; i++) {
            uint256 projectId = _projectIds[i];
            projectReferrals[_users[i]][projectId].totalRewardsTokens += _amounts[i];
            rewardTokensAmount[projectId] += _amounts[i];
        }
    }
}
