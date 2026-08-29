// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Pyth price feed interface
/// @notice Price = price * 10^expo (price and conf are fixed-point). Use getPrice in production; never getPriceUnsafe.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice Safe: returns price with validity check (reverts if stale/expired). Use in production.
    function getPrice(bytes32 id) external view returns (Price memory);

    /// @notice Unsafe: no recency/confidence check. Use only for off-chain or with manual checks.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}
