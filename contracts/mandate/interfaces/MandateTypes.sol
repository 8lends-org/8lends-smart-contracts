// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Mandate escrow shared types
/// @notice Shapes shared by the factory, router and escrow. this file only fixes the wire format.

/// @notice Where interest goes. Declared beside the struct rather than inside it: the field stays
///         `uint8` so an out-of-range value reverts with a named error instead of the decoder's
///         empty revert, and so `type(InterestDirection).max` is the bound the check reads.
/// @dev KEEP must stay zero — it is the default of a fresh mandate.
enum InterestDirection {
    KEEP,   // back into the mandate
    WALLET, // to the owner's wallet
    LEND    // supplied into Lending8 on the owner's behalf
}

/// @notice Rules baked into the escrow address. Changing any field means a different escrow.
/// @dev The V1 suffix is part of the contract with the backend: this struct's composition is hashed
///      into paramsHash and therefore into the address, so it can never be extended in place. A
///      later ImmutableParamsV2 arrives alongside MandateEscrowV2, leaving v1 mandates untouched.
/// @dev Both phase-1 parameters are here, so a mandate has no mutable settings at all — nothing
///      about it changes after creation, by the owner or by the platform.
struct ImmutableParamsV1 {
    /// @notice An {InterestDirection}, held as its underlying type — see the enum for why.
    uint8 interestDirection;

    /// @notice Share of the mandate that may go into a single project, in basis points.
    /// @dev Binding only above minAllocation(): below it the minimum ticket is placed instead, so a
    ///      mandate smaller than minAllocation * 10000 / projectLimitBps concentrates more than the
    ///      owner chose.
    uint16 projectLimitBps;
}

/// @notice Two states only. "Not enough balance to place" is not one — derive it from freeBalance()
///         against minAllocation().
enum MandateState {
    ACTIVE,
    PAUSED_BY_OWNER
}
