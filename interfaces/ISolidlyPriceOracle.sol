// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19;

interface ISolidlyOracle {
    function getPrice(address tokenIn, uint256 amountIn) external view returns (uint256 price);
}
