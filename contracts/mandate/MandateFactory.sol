// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IMandateFactory } from "./interfaces/IMandateFactory.sol";
import { IMandateEscrowV1 } from "./interfaces/IMandateEscrowV1.sol";
import { ImmutableParamsV1, InterestDirection } from "./interfaces/MandateTypes.sol";

/// @title MandateFactory
/// @notice Creates mandate escrows and answers whether an address really is one. Upgradeable, so
///         the KYC signer and the current implementation change without touching immutable clones.
/// @dev Keeps no per-escrow records. Ownership is re-derived from the address itself, so there is
///      no membership table to fall out of step with reality, and no list to migrate.
contract MandateFactory is IMandateFactory, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 private constant BPS = 10_000;

    /// @dev Where EIP-1167 keeps the implementation address inside the clone's runtime code.
    uint256 private constant CLONE_IMPL_OFFSET = 10;

    address public kycSigner;
    uint16 public latestVersion;
    mapping(uint16 => address) public implementations;

    error ZeroAddress();
    error BadInterestDirection(uint8 direction);
    error BadProjectLimitBps(uint16 bps);
    error NotKycSigner();
    error NoImplementation(uint16 version);
    error VersionNotNewer(uint16 version, uint16 latest);
    error ZeroVersion();
    error VersionMismatch(uint16 registering, uint16 reported);
    error ImplementationHasNoCode(address impl);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address kycSigner_) external initializer {
        if (owner_ == address(0) || kycSigner_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        kycSigner = kycSigner_;
    }

    // ── user ────────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateFactory
    function createMandate(ImmutableParamsV1 calldata p, bytes calldata kyc)
        external
        returns (address escrow)
    {
        if (p.interestDirection > uint8(type(InterestDirection).max)) {
            revert BadInterestDirection(p.interestDirection);
        }
        if (p.projectLimitBps == 0 || p.projectLimitBps > BPS) {
            revert BadProjectLimitBps(p.projectLimitBps);
        }

        uint16 version = latestVersion;
        address impl = implementations[version];
        if (impl == address(0)) revert NoImplementation(version);

        // abi.encode, not encodePacked — it hashes a struct, and the escrow computes it the same way.
        bytes32 paramsHash = keccak256(abi.encode(p));
        _requireKycSignerSig(msg.sender, paramsHash, version, kyc);

        // A repeat lands on occupied code and reverts inside cloneDeterministic, which is what makes
        // the signature single-use without a nonce.
        escrow = Clones.cloneDeterministic(impl, _salt(msg.sender, version, paramsHash));
        IMandateEscrowV1(escrow).initialize(msg.sender, p);

        emit MandateCreated(msg.sender, escrow, version, paramsHash);
    }

    // ── views ───────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateFactory
    function predictMandateAddress(address owner_, bytes32 paramsHash, uint16 version)
        public
        view
        returns (address)
    {
        address impl = implementations[version];
        if (impl == address(0)) revert NoImplementation(version);
        return Clones.predictDeterministicAddress(impl, _salt(owner_, version, paramsHash), address(this));
    }

    /// @inheritdoc IMandateFactory
    function isEscrowOf(address owner_, address escrow) external view returns (bool) {
        // Must be the first line: a mandate address is known before it exists, so a pre-flight call
        // has to get a plain false rather than a reverting staticcall below.
        if (escrow.code.length == 0) return false;

        uint16 version;
        bytes32 paramsHash;
        try IMandateEscrowV1(escrow).version() returns (uint16 v) {
            version = v;
        } catch {
            return false;
        }
        try IMandateEscrowV1(escrow).paramsHash() returns (bytes32 h) {
            paramsHash = h;
        } catch {
            return false;
        }

        // From the clone's own bytecode, not implementations[version] — the answer stays valid
        // whatever happens to the registry afterwards.
        address impl = _implementationOf(escrow);
        if (impl == address(0)) return false;

        // What the clone says about itself is safe to trust: false data lands on another address,
        // and a contract cannot move itself. `owner_` comes from the caller, which is what binds
        // the answer to the owner being asked about.
        return Clones.predictDeterministicAddress(impl, _salt(owner_, version, paramsHash), address(this)) == escrow;
    }

    // ── owner ───────────────────────────────────────────────────────────────────

    /// @inheritdoc IMandateFactory
    function setKycSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        kycSigner = signer;
    }

    /// @inheritdoc IMandateFactory
    function registerImplementation(uint16 version, address impl) external onlyOwner {
        if (version == 0) revert ZeroVersion();
        if (impl.code.length == 0) revert ImplementationHasNoCode(impl); // covers the zero address
        // Strictly increasing, which is also what makes a number impossible to reuse: registering a
        // version sets latestVersion to it, so every taken number is already <= latestVersion. And
        // reuse would move the derived address of every escrow created under that number.
        if (version <= latestVersion) revert VersionNotNewer(version, latestVersion);

        uint16 reported;
        try IMandateEscrowV1(impl).version() returns (uint16 v) {
            reported = v;
        } catch {
            reported = 0; // unreadable counts as a mismatch; zero is never a valid version
        }
        if (reported != version) revert VersionMismatch(version, reported);

        implementations[version] = impl;
        latestVersion = version;

        emit ImplementationRegistered(version, impl);
    }

    // ── internals ───────────────────────────────────────────────────────────────

    /// @dev Every future salt scheme must keep binding all three of owner, version and paramsHash:
    ///      a branch that drops the owner is the one a forgery would pick.
    function _salt(address owner_, uint16 version, bytes32 paramsHash) private pure returns (bytes32) {
        return keccak256(abi.encode(owner_, version, paramsHash));
    }

    /// @dev Same scheme as the live investUpdateV2 path, so the backend needs no new signing flow.
    ///      encodePacked is safe here — every field is fixed-size, and `version` packs to two bytes.
    ///      ECDSA.recover rejects a malleable high-s signature on its own.
    function _requireKycSignerSig(address owner_, bytes32 paramsHash, uint16 version, bytes calldata sig)
        private
        view
    {
        bytes32 inner = keccak256(abi.encodePacked(owner_, paramsHash, version, address(this), block.chainid));
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(inner), sig) != kycSigner) {
            revert NotKycSigner();
        }
    }

    /// @dev The 20 bytes EIP-1167 stores at offset 10 of the clone's runtime code. Returns zero for
    ///      anything whose code is too short to be a clone.
    function _implementationOf(address clone) private view returns (address impl) {
        if (clone.code.length < CLONE_IMPL_OFFSET + 20) return address(0);
        assembly {
            let ptr := mload(0x40)
            extcodecopy(clone, ptr, CLONE_IMPL_OFFSET, 20)
            impl := shr(96, mload(ptr))
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
