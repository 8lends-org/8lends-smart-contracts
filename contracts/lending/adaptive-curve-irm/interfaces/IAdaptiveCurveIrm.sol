// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IIrm} from "../../interfaces/IIrm.sol";
import {Id} from "../../interfaces/ILending8.sol";

/// @title IAdaptiveCurveIrm
/// @author 8lends

/// @notice Interface exposed by the AdaptiveCurveIrm.
interface IAdaptiveCurveIrm is IIrm {
    /// @notice Address of Lending8.
    function LENDING8() external view returns (address);

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    function rateAtTarget(Id id) external view returns (int256);
}
