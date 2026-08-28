// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IEscrowFactory {
    function usdc() external view returns (address);
    function fundraise() external view returns (address);
    function maxInvestAmount() external view returns (uint256);
    function minInvestAmount() external view returns (uint256);
    function refundTimeout() external view returns (uint256);

    /// @notice Returns the escrow address registered for a user (zero if none)
    /// @dev Used by Fundraise.investFromEscrow to verify that msg.sender is
    ///      the legitimate escrow registered for `_investor`
    function escrows(address user) external view returns (address);

    /// @notice Callback from AmlEscrow.invest() — emits indexer-friendly event on Factory address
    function onInvestRequested(address user, uint256 requestId, uint256 pid, uint256 amount, address inviter, uint256 createdAt, uint256 cancelAfter) external;

    /// @notice Callback from AmlEscrow.cancelRequest() — emits indexer-friendly event on Factory address
    function onRequestCancelled(address user, uint256 requestId, uint256 pid, uint256 amount, address inviter) external;
}
