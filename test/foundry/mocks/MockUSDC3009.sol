// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { MockUSDC } from "./MockUSDC.sol";

/// @notice MockUSDC plus a real EIP-3009 `receiveWithAuthorization` — signatures actually verified,
///         because the value of the escrow's deposit path is in what the token enforces.
/// @dev Separate from `MockUSDC`, which seventeen suites share. Temporary: NEW-13 gives
///      `contracts/test-tokens/usdc.sol` EIP-3009, after which this file goes away.
/// @dev Test double only, never deployed.
contract MockUSDC3009 is MockUSDC {
    /// @dev Must equal the constant in the deployed FiatTokenV2_2; `test_typehash_matches_usdc`
    ///      pins it.
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Digest a payer signs. Exposed so tests sign the same bytes the contract checks.
    function receiveDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        // What makes this variant safe for the escrow: spendable only by the recipient itself.
        require(msg.sender == to, "FiatTokenV2: caller must be the payee");
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(!authorizationState[from][nonce], "FiatTokenV2: authorization is used or canceled");

        bytes32 digest = receiveDigest(from, to, value, validAfter, validBefore, nonce);
        require(ECDSA.recover(digest, signature) == from, "FiatTokenV2: invalid signature");

        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, value);
    }
}
