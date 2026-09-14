// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title IMandateFundraise — the one thing an escrow needs Fundraise to add
/// @notice Placement entry point used by MandateEscrowV1. Everything else the escrow reads from
///         Fundraise (`projects`, `investorInfo`) already exists and comes from IFundraise.
/// @dev Kept apart from IFundraise on purpose: Fundraise does not implement this yet — it arrives
///      with EL-1814 — and adding the declaration to the shared interface would break Fundraise's
///      own compilation until then. Fold it into IFundraise once EL-1814 lands.
interface IMandateFundraise {
    /// @notice Places `amount` of the escrow's USDC into `pid`, recording `owner` as the investor.
    /// @dev The escrow approves exactly `amount` immediately before the call and resets the
    ///      allowance to zero immediately after, so no standing allowance is left behind.
    /// @param owner Address recorded as the investor — the mandate's owner, never the escrow
    /// @param pid Project to place into
    /// @param amount USDC to place, computed by the escrow
    /// @param inviter Referral address, or zero to skip both the inviter binding and the accrual
    function investFromMandate(address owner, uint256 pid, uint256 amount, address inviter) external;
}
