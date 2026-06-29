// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {MarketParams, Market} from "./ILending8.sol";

/// @title IIrm
/// @author 8lends

/// @notice Interface that Interest Rate Models (IRMs) used by Lending8 must implement.
interface IIrm {
    /// @notice Returns the borrow rate per second (scaled by WAD) of the market `marketParams`.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256);

    /// @notice Returns the borrow rate per second (scaled by WAD) of the market `marketParams` without modifying any
    /// storage.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256);
}
