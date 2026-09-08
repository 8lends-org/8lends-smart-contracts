// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.23;

interface ITreasury {
    function claim(address _token, uint256 _amount, address _recepient) external;
}
