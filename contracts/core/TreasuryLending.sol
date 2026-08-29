// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.23;

import "./Treasury.sol";

/// @dev Same logic as Treasury, separate instance (e.g. for lending fees). Name only differs.
contract TreasuryLending is Treasury {}