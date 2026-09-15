// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ImmutableParamsV1 } from "./MandateTypes.sol";

/// @title IMandateFactory
/// @notice Creates mandate escrows and keeps the version registry. Upgradeable, so the KYC signer
///         and the current implementation can change without touching the immutable clone.
/// @dev One user can hold several mandates. The bound is one mandate per distinct parameter set:
///      identical params give the same salt, hence the same address, and cloneDeterministic
///      reverts on occupied code. Since projectLimitBps is part of the set, that bound is not a
///      small number — every percentage is its own address. What limits mandates in practice is
///      the interface, not this contract.
interface IMandateFactory {
    event MandateCreated(
        address indexed owner,
        address indexed escrow,
        uint16 version,
        bytes32 paramsHash
    );

    /// @notice A new implementation became current: from here on createMandate issues only that
    ///         version, and its number goes into the KYC signature preimage.
    event ImplementationRegistered(uint16 version, address impl);

    // ── views ───────────────────────────────────────────────────────────────────

    /// @dev The factory keeps no per-escrow records: no owner, no version, no list. Ownership is
    ///      proven by re-deriving the CREATE2 address (isEscrowOf below), and the
    ///      owner → mandates link is assembled off chain from MandateCreated.
    function implementations(uint16 version) external view returns (address);

    /// @notice Version createMandate will use. Also what goes into the KYC signature preimage.
    function latestVersion() external view returns (uint16);

    /// @notice Whose signature createMandate accepts. The factory's own field, not Fundraise's
    ///         trustedSigner — reading that from an upgradeable contract inside the creation path
    ///         would be a dependency for nothing, and a slot is cheaper.
    /// @dev The key MAY be the same one the backend already signs investUpdateV2 with; then nothing
    ///      changes on its side except the preimage. Compare this getter against that key before
    ///      going live: a mismatch reverts every createMandate.
    function kycSigner() external view returns (address);

    /// @notice Address a mandate would get, before creating it.
    /// @dev salt = keccak256(abi.encode(owner, version, paramsHash)) — abi.encode, not
    ///      encodePacked.
    function predictMandateAddress(address owner, bytes32 paramsHash, uint16 version)
        external
        view
        returns (address);

    /// @notice True only for an escrow this owner really owns. The protocol's single
    ///         implementation of that check: the router calls it from setRoute/setRouteMany/
    ///         enrollSelf, Fundraise from investFromMandate, Market when a lot is listed with a
    ///         proceeds recipient. Callers get the factory address from the registry's address
    ///         book and MUST revert on a zero address rather than skip the check.
    /// @dev Returns false, not a revert, for an address with no code. The check itself has to be
    ///      the first line: the derivation reads paramsHash(), version() and owner() off the escrow,
    ///      and on an empty address those staticcalls revert. A mandate address is deterministic and
    ///      known BEFORE creation, so a backend pre-flight call would otherwise get an RPC error
    ///      instead of a plain false. On-chain callers see no difference — they revert either way.
    /// @dev Derived, not read from storage — the factory keeps no membership records:
    ///      implementation from the clone's EIP-1167 bytecode (20 bytes at offset 10), paramsHash
    ///      and version from the escrow itself, salt = keccak256(abi.encode(owner, version,
    ///      paramsHash)), then CREATE2 recomputed and compared against the address itself. A clone
    ///      cannot lie about its own owner: false data lands on a different address, and it cannot
    ///      move itself.
    /// @dev It lives here, not in the router, because the derivation is a property of THIS
    ///      contract's address scheme — salt, how the implementation is obtained, its own address.
    ///      One implementation, so predictMandateAddress and this check cannot drift apart.
    /// @dev Future salt schemes branch INSIDE this function on `version`, which is part of the salt,
    ///      so old escrows keep validating under the old branch and no second factory address is
    ///      ever needed. The branch is selected by a value the escrow reports about itself, which is
    ///      safe only because the final address comparison is the proof — therefore every branch
    ///      MUST bind all three of owner, version and paramsHash. A branch that leaves the owner out
    ///      of the salt would be a hole, since a forgery would pick exactly that one.
    /// @dev Consequence for procedure: an upgrade of this contract can make this check lie, and via
    ///      enrollSelf that redirects a user's future payouts. The factory is therefore a
    ///      money-path contract — its upgrades are audited and announced like Fundraise's.
    function isEscrowOf(address owner, address escrow) external view returns (bool);

    // ── user ────────────────────────────────────────────────────────────────────

    /// @notice Creates the caller's mandate and returns its address.
    /// @dev The KYC signature is verified here, not in the escrow — this is the only gate that
    ///      keeps unverified users out, since the placement path has no signature check.
    /// @dev Digest, identical in scheme to the live investUpdateV2 path (Fundraise.sol:237-243), so
    ///      the backend needs no new signing flow:
    ///        inner  = keccak256(abi.encodePacked(msg.sender, paramsHash, version,
    ///                                            address(this), block.chainid))
    ///        digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner))
    ///      checked against kycSigner() with malleability protection. Three traps: encodePacked
    ///      and NOT encode (every type is fixed-size here, so there is no ambiguity); the EIP-191
    ///      prefix is mandatory, i.e. sign `digest`, not `inner`; and version is a uint16, two
    ///      bytes when packed. paramsHash itself uses abi.encode — it hashes a struct, where
    ///      encodePacked would collide across field-set changes. Same for the salt:
    ///      keccak256(abi.encode(owner, version, paramsHash)).
    /// @dev The signature carries no nonce and no deadline, which has two consequences a caller
    ///      must plan for. It is single-use anyway: the salt is keccak256(owner, version,
    ///      paramsHash), so it authorises exactly one address, and a second attempt hits occupied
    ///      code and reverts in cloneDeterministic. But it cannot be revoked and stays usable for
    ///      its one mandate forever, so KYC freshness has to be enforced where money moves — the
    ///      operator checks eligibility before calling allocate.
    /// @dev No amount and no minimum here: the deposit is a separate call on the escrow, and a
    ///      mandate funded purely by routing existing investments is created with no deposit at
    ///      all. The only number in the system is escrow.minAllocation(), and it governs
    ///      placement, not funding.
    /// @dev Bounds are checked here AND in the escrow's initializer: interestDirection within
    ///      {InterestDirection}, 0 < projectLimitBps <= 10000. The escrow's copy is the load-bearing one — a clone is
    ///      immutable, and an out-of-range set would yield a working escrow at a derived address
    ///      that passes isEscrowOf.
    /// @param p Both rules of the mandate, baked into the address. All three {InterestDirection}
    ///          values are accepted from phase 1 — KEEP, WALLET and LEND. The lending pool is not part of these params — it is supplied per call as
    ///          the third argument of Fundraise.claimForMandate and forwarded through onPayout; no
    ///          constant is stored on chain. There is no second params argument:
    ///          the mandate has no mutable settings, so paramsHash covers everything the owner
    ///          chose — including the percentage, which the KYC signature therefore also covers
    /// @param kyc Backend signature confirming the caller passed KYC, as raw bytes
    function createMandate(ImmutableParamsV1 calldata p, bytes calldata kyc)
        external
        returns (address escrow);

    // ── owner of the factory ────────────────────────────────────────────────────

    /// @notice Rotates the KYC signer. One transaction, not an upgrade — an upgrade to swap a hot
    ///         key is operationally worse and adds nothing.
    /// @dev Gated by the factory's owner, i.e. the multisig — this key decides who may create a
    ///      mandate at all, so a self-extending role is not enough for it. Signatures issued by the
    ///      previous key stop being accepted immediately, so a rotation has to be coordinated with
    ///      the backend.
    function setKycSigner(address signer) external;

    /// @notice Registers a new implementation and makes it the latest.
    /// @dev createMandate takes no version argument and always uses latestVersion, so this call
    ///      also closes creation on the previous version. Existing clones are immutable and keep
    ///      working regardless.
    function registerImplementation(uint16 version, address impl) external;
}
