// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IFundraise {
    function investorInfo(address investor, uint256 projectId)
        external
        view
        returns (uint256 investedAmount, uint256 totalClaimed);
}
