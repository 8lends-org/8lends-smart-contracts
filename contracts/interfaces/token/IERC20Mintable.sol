// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.23;

interface IERC20Mintable {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}
