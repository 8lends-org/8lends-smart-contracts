// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

/// @notice Minimal Uniswap V3 pool interface for TWAP oracle (observe, token0, token1).
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
