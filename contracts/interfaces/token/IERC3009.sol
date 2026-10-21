// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

/**
 * @dev Interface of the ERC-3009 standard as defined in https://eips.ethereum.org/EIPS/eip-3009[ERC-3009].
 *
 * The EIP defines the `v, r, s` form of each call. Circle's FiatTokenV2_2 — the USDC we integrate
 * with — additionally exposes a `bytes signature` overload of both, which is the one to use when the
 * signer may be a smart account: an ERC-1271 signature is arbitrary-length bytes and does not fit in
 * three fixed fields. Both are declared here because the deployed token has both.
 */
interface IERC3009 {
    /// @dev Emitted when an authorization is used.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    /**
     * @dev Returns the state of an authorization.
     *
     * Nonces are randomly generated 32-byte values unique to the authorizer's address. Consumed only
     * on success or cancellation — an expired authorization leaves its nonce reusable.
     */
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    /**
     * @dev Executes a transfer with a signed authorization.
     *
     * Requirements:
     *
     * * `validAfter` must be less than the current block timestamp.
     * * `validBefore` must be greater than the current block timestamp.
     * * `nonce` must not have been used by the `from` account.
     * * the signature must be valid for the authorization.
     *
     * NOTE: This variant does not restrict who may submit the authorization, so the transfer can
     * land without the recipient's own code running. Where that matters, use
     * {receiveWithAuthorization}.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @dev Same as {transferWithAuthorization}, with the signature as bytes so ERC-1271 signers work.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    /**
     * @dev Receives a transfer with a signed authorization from the payer.
     *
     * Includes an additional check to ensure that the payee's address (`to`) matches the caller
     * to prevent front-running attacks.
     *
     * Requirements:
     *
     * * `to` must be the caller of this function.
     * * `validAfter` must be less than the current block timestamp.
     * * `validBefore` must be greater than the current block timestamp.
     * * `nonce` must not have been used by the `from` account.
     * * the signature must be valid for the authorization.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @dev Same as {receiveWithAuthorization}, with the signature as bytes so ERC-1271 signers work.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/**
 * @dev Extension of {IERC3009} that adds the ability to cancel authorizations.
 */
interface IERC3009Cancel {
    /// @dev Emitted when an authorization is canceled.
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /**
     * @dev Cancels an authorization.
     *
     * Requirements:
     *
     * * `nonce` must not have been used by the `authorizer` account.
     * * the signature must be valid for the cancellation.
     */
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;

    /// @dev Same as {cancelAuthorization}, with the signature as bytes so ERC-1271 signers work.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external;
}
