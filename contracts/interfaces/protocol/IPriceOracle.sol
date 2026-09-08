// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Oracle for collateral price in USDT (6 decimals)
/// @dev getPrice returns USDT value (6 decimals) per 10**decimals(collateralToken) of collateral
interface IPriceOracle {
    /// @notice Get price of collateral token in USDT
    /// @param _collateralToken Collateral token address
    /// @return Price in USDT (6 decimals) per 10**decimals(_collateralToken) units of collateral
    function getPrice(address _collateralToken) external view returns (uint256);
}
