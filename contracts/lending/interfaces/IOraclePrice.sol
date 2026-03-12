// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IOraclePrice
/// @author 8lends

/// @notice Minimal interface for global oracle used by Lending8: getPrice(token).price = USD price (same scale for all tokens).
/// @dev Struct layout must match Oracle.PriceResult for ABI compatibility.
interface IOraclePrice {
    function priceDecimals() external view returns (uint8);

    struct PriceResult {
        uint256 pythPrice;
        uint256 chainLinkPrice;
        uint256 uniswapPrice;
        uint256 price;
        uint8 priceSource;
        uint256 pythUpdatedAt;
        uint256 chainLinkUpdatedAt;
    }

    function getPrice(address token) external view returns (PriceResult memory);
}
