// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.23;

interface IToken {
    function mintReward(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}
