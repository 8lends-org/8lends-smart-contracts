// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author 8lends

/// @notice Library exposing error messages.
library ErrorsLib {
    /// @dev Thrown when passing the zero address.
    string internal constant ZERO_ADDRESS = "zero address";

    /// @dev Thrown when the caller is not Lending8.
    string internal constant NOT_LENDING8 = "not Lending8";
}
