// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Oracle interface for Lending: price (priceDecimals) and source.
interface IOracle {
    enum PriceSource {
        None,
        Pyth,
        ChainLink,
        Uniswap
    }

    struct PriceResult {
        uint256 pythPrice;
        uint256 chainLinkPrice;
        uint256 uniswapPrice;
        uint256 price;
        PriceSource priceSource;
        uint256 pythUpdatedAt;
        uint256 chainLinkUpdatedAt;
    }

    function getPrice(address _token) external view returns (PriceResult memory);
    function priceDecimals() external view returns (uint8);
}
