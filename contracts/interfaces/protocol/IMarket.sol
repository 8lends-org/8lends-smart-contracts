// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.23;

interface IMarket {
    function secondaryInvestedAmount(address _user, uint256 _projectId) external view returns (uint256);
}
