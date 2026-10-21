// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import "./testerc20.sol";

/// @notice Test USDC: TestERC20 plus the two pieces of real USDC the mandate flow depends on —
///         EIP-3009 authorizations and a blacklist. Sepolia only.
/// @dev Not the full FiatTokenV2_2: its storage layout is incompatible, so adopting it would mean a
///      new address, rewriting every reference and re-minting balances.
/// @dev `transferWithAuthorization` is not implemented — it does not require msg.sender == to, so an
///      authorization could be spent by anyone to move funds into a contract without that
///      contract's own code running.
/// @dev The domain reads `name()` live, so it follows `rename`; the token must be renamed to
///      "USD Coin" to match Base. chainId and verifyingContract still differ, and must — they are
///      what stops a Sepolia signature being replayed on Base.
contract USDC is TestERC20 {
    /// @dev Must equal Circle's 0xd099cc98…13de8. The type name is part of the hashed string, so the
    ///      same fields under another name hash differently — and a mismatch surfaces only as
    ///      `invalid signature`.
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @custom:storage-location erc7201:8lends.storage.TestUSDC
    struct USDCStorage {
        mapping(address => mapping(bytes32 => bool)) authorizationStates;
        mapping(address => bool) blacklisted;
    }

    /// @dev Its own namespace, not fields on this contract: a field here would land right after
    ///      TestERC20's `_decimals`, and any future change to the parent would shift it out from
    ///      under the deployed proxy.
    bytes32 private constant USDC_STORAGE_SLOT =
        0xd45004ee24312b299a48c83657035f913a7bda699dde6804ba4904eace8ea700;

    function _usdcStorage() private pure returns (USDCStorage storage $) {
        assembly {
            $.slot := USDC_STORAGE_SLOT
        }
    }

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    // ── EIP-3009 ────────────────────────────────────────────────────────────────

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Whether an authorization has been used or cancelled. Doubles as an idempotency read
    ///         for the backend: "did this deposit land".
    /// @dev Expiry does not consume a nonce — only success or an explicit cancellation does.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _usdcStorage().authorizationStates[authorizer][nonce];
    }

    /// @notice Pulls `value` from `from` against their signature. Only the payee may submit it,
    ///         which pins the authorization to the recipient's own call.
    /// @dev `bytes` rather than v/r/s so ERC-1271 smart accounts work: their signature is
    ///      arbitrary-length and does not fit three fixed fields.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        _requireValidAuthorization(from, nonce, validAfter, validBefore);

        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        _requireValidSignature(from, structHash, signature);

        _usdcStorage().authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);

        _transfer(from, to, value);
    }

    /// @notice Burns a nonce so its authorization can never be used.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        USDCStorage storage $ = _usdcStorage();
        require(!$.authorizationStates[authorizer][nonce], "FiatTokenV2: authorization is used or canceled");

        _requireValidSignature(
            authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), signature
        );

        $.authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _requireValidAuthorization(
        address authorizer,
        bytes32 nonce,
        uint256 validAfter,
        uint256 validBefore
    ) private view {
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        require(
            !_usdcStorage().authorizationStates[authorizer][nonce],
            "FiatTokenV2: authorization is used or canceled"
        );
    }

    /// @dev Open-coded because OpenZeppelin's SignatureChecker needs solc ^0.8.24 and this repo is
    ///      pinned to 0.8.23. The logic is theirs: ECDSA for an EOA, ERC-1271 for a signer with code.
    function _requireValidSignature(address signer, bytes32 structHash, bytes calldata signature) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        bool ok;
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);
            ok = err == ECDSA.RecoverError.NoError && recovered == signer;
        } else {
            (bool success, bytes memory result) =
                signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, signature)));
            ok = success && result.length >= 32
                && abi.decode(result, (bytes32)) == bytes32(IERC1271.isValidSignature.selector);
        }

        require(ok, "FiatTokenV2: invalid signature");
    }

    // ── blacklist ───────────────────────────────────────────────────────────────

    function isBlacklisted(address account) external view returns (bool) {
        return _usdcStorage().blacklisted[account];
    }

    function blacklist(address account) external onlyOwner {
        _usdcStorage().blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unBlacklist(address account) external onlyOwner {
        _usdcStorage().blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    /// @dev The single hook transfers, mints and burns all pass through. Reverting on a blacklisted
    ///      counterparty is the intended outcome: the platform must not move money on a blocked
    ///      address's behalf.
    /// @dev One message for both directions, verbatim from the deployed FiatTokenV2_2. Naming the
    ///      side would read better but would make a backend that matches on the string behave
    ///      differently here and on Base.
    function _update(address from, address to, uint256 value) internal virtual override {
        USDCStorage storage $ = _usdcStorage();
        require(!$.blacklisted[from], "Blacklistable: account is blacklisted");
        require(!$.blacklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}
