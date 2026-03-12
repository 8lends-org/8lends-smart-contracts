// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title ILending8LiquidateCallback
/// @notice Interface that liquidators willing to use `liquidate`'s callback must implement.
interface ILending8LiquidateCallback {
    /// @notice Callback called when a liquidation occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param repaidAssets The amount of repaid assets.
    /// @param data Arbitrary data passed to the `liquidate` function.
    function onLending8Liquidate(uint256 repaidAssets, bytes calldata data) external;
}

/// @title ILending8RepayCallback
/// @notice Interface that users willing to use `repay`'s callback must implement.
interface ILending8RepayCallback {
    /// @notice Callback called when a repayment occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of repaid assets.
    /// @param data Arbitrary data passed to the `repay` function.
    function onLending8Repay(uint256 assets, bytes calldata data) external;
}

/// @title ILending8SupplyCallback
/// @notice Interface that users willing to use `supply`'s callback must implement.
interface ILending8SupplyCallback {
    /// @notice Callback called when a supply occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of supplied assets.
    /// @param data Arbitrary data passed to the `supply` function.
    function onLending8Supply(uint256 assets, bytes calldata data) external;
}

/// @title ILending8SupplyCollateralCallback
/// @notice Interface that users willing to use `supplyCollateral`'s callback must implement.
interface ILending8SupplyCollateralCallback {
    /// @notice Callback called when a supply of collateral occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of supplied collateral.
    /// @param data Arbitrary data passed to the `supplyCollateral` function.
    function onLending8SupplyCollateral(uint256 assets, bytes calldata data) external;
}

/// @title ILending8FlashLoanCallback
/// @notice Interface that users willing to use `flashLoan`'s callback must implement.
interface ILending8FlashLoanCallback {
    /// @notice Callback called when a flash loan occurs.
    /// @dev The callback is called only if data is not empty.
    /// @param assets The amount of assets that was flash loaned.
    /// @param data Arbitrary data passed to the `flashLoan` function.
    function onLending8FlashLoan(uint256 assets, bytes calldata data) external;
}
