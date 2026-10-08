// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../../contracts/core/Rewards2.sol";

/// @dev Rewards2 can no longer create vesting, yet every vesting it pays out was created by it
///      before that. Tests reproduce that state here, written the way createVesting used to write it.
contract Rewards2Harness is Rewards2 {
    function seedVestings(address[] calldata _users, uint256[] calldata _amounts) external {
        require(_users.length == _amounts.length, "Users and amounts length mismatch");
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 vestingId = userVestingCount[user];
            vestings[user][vestingId] = Vesting({
                totalAmount: _amounts[i],
                claimedAmount: 0,
                startTime: block.timestamp,
                isActive: true
            });
            userVestingCount[user]++;
            totalVestings++;
        }
    }
}
