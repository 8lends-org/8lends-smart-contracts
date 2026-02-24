// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IERC20
/// @author 8lends

/// @dev Empty because we only call library functions. It prevents calling transfer (transferFrom) instead of
/// safeTransfer (safeTransferFrom).
interface IERC20 {}
