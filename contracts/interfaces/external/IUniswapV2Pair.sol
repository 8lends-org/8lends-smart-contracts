// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
