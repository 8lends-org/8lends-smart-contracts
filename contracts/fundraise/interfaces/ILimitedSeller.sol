// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ILimitedSeller {
    function addEarnedLimit(address user, uint256 investedAmount) external;
}
