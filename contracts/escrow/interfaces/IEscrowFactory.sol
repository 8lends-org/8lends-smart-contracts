// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IEscrowFactory {
    function usdc() external view returns (address);
    function fundraise() external view returns (address);
    function maxInvestAmount() external view returns (uint256);
    function minInvestAmount() external view returns (uint256);
    function refundTimeout() external view returns (uint256);
}
