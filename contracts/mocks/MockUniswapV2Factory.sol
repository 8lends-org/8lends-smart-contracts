// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Mock Uniswap V2 factory. Only getPair matters: FlashLiquidator reads a non-zero pair as
/// "collateral is swappable" and only then uses flash liquidity. The pair is never called, so any
/// non-zero address will do.
contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) private _pairs;

    function setPair(address tokenA, address tokenB, address pair) external {
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }

    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return _pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB)))));
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }
}
