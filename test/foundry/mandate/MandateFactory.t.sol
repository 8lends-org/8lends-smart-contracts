// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { MandateFactory } from "../../../contracts/mandate/MandateFactory.sol";
import { MandateEscrowV1 } from "../../../contracts/mandate/MandateEscrowV1.sol";
import { IMandateFactory } from "../../../contracts/mandate/interfaces/IMandateFactory.sol";
import { ImmutableParamsV1, InterestDirection } from "../../../contracts/mandate/interfaces/MandateTypes.sol";

/// @dev Reports whatever it is told to, to prove the address comparison is the only thing that
///      decides — a contract that lies about itself simply lands somewhere else.
contract LyingEscrow {
    uint16 public version;
    bytes32 public paramsHash;

    constructor(uint16 v, bytes32 h) {
        version = v;
        paramsHash = h;
    }
}

/// @dev Implementations that differ only in the number they report — enough for the registry,
///      which never calls anything else on them.
contract EscrowV1Twin { function version() external pure returns (uint16) { return 1; } }
contract EscrowV2     { function version() external pure returns (uint16) { return 2; } }
contract EscrowV3     { function version() external pure returns (uint16) { return 3; } }
contract EscrowV5     { function version() external pure returns (uint16) { return 5; } }

contract MandateFactoryTest is Test {
    MandateFactory factory;
    MandateEscrowV1 implV1;

    uint256 kycKey = 0x5160;
    address kycSigner;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    ImmutableParamsV1 params = ImmutableParamsV1({
        interestDirection: uint8(InterestDirection.WALLET),
        projectLimitBps: 1000
    });

    function setUp() public {
        kycSigner = vm.addr(kycKey);

        implV1 = new MandateEscrowV1(
            address(0x5D6), address(0xF0A), address(0x4E6), address(0x40E), address(0x1E4D)
        );

        factory = MandateFactory(address(new ERC1967Proxy(
            address(new MandateFactory()),
            abi.encodeCall(MandateFactory.initialize, (address(this), kycSigner))
        )));
        factory.registerImplementation(1, address(implV1));
    }

    function _paramsHash(ImmutableParamsV1 memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function _kyc(uint256 key, address owner_, ImmutableParamsV1 memory p, uint16 version)
        internal
        view
        returns (bytes memory)
    {
        bytes32 inner = keccak256(
            abi.encodePacked(owner_, _paramsHash(p), version, address(factory), block.chainid)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── creation ────────────────────────────────────────────────────────────────

    function test_creates_the_escrow_at_the_predicted_address() public {
        address predicted = factory.predictMandateAddress(alice, _paramsHash(params), 1);

        vm.expectEmit(true, true, false, true, address(factory));
        emit IMandateFactory.MandateCreated(alice, predicted, 1, _paramsHash(params));
        vm.prank(alice);
        address escrow = factory.createMandate(params, _kyc(kycKey, alice, params, 1));

        assertEq(escrow, predicted, "predictMandateAddress must agree with reality");
        assertEq(MandateEscrowV1(escrow).owner(), alice);
        assertEq(MandateEscrowV1(escrow).paramsHash(), _paramsHash(params));
        assertEq(MandateEscrowV1(escrow).params().interestDirection, uint8(InterestDirection.WALLET));
    }

    /// The only gate keeping unverified users out — the placement path checks no signature at all.
    function test_creation_needs_the_kyc_signature() public {
        vm.expectRevert(MandateFactory.NotKycSigner.selector);
        vm.prank(alice);
        factory.createMandate(params, _kyc(0xBAD, alice, params, 1));
    }

    /// Signed for Alice, submitted by Bob: the owner is in the preimage, so it does not transfer.
    function test_kyc_signature_is_bound_to_the_caller() public {
        vm.expectRevert(MandateFactory.NotKycSigner.selector);
        vm.prank(bob);
        factory.createMandate(params, _kyc(kycKey, alice, params, 1));
    }

    /// The params are in the preimage too, so a signature cannot be spent on a different mandate.
    function test_kyc_signature_is_bound_to_the_params() public {
        ImmutableParamsV1 memory other = ImmutableParamsV1({
            interestDirection: uint8(InterestDirection.LEND),
            projectLimitBps: 1000
        });
        vm.expectRevert(MandateFactory.NotKycSigner.selector);
        vm.prank(alice);
        factory.createMandate(other, _kyc(kycKey, alice, params, 1));
    }

    /// No nonce and no deadline, but the salt authorises exactly one address — the second attempt
    /// lands on occupied code.
    function test_the_same_parameters_cannot_be_created_twice() public {
        bytes memory sig = _kyc(kycKey, alice, params, 1);
        vm.prank(alice);
        factory.createMandate(params, sig);

        vm.expectRevert(Errors.FailedDeployment.selector);
        vm.prank(alice);
        factory.createMandate(params, sig);
    }

    /// Every distinct parameter set is its own address, so a user may hold several mandates.
    function test_a_second_mandate_with_other_params_is_a_different_address() public {
        vm.prank(alice);
        address first = factory.createMandate(params, _kyc(kycKey, alice, params, 1));

        ImmutableParamsV1 memory other = ImmutableParamsV1({
            interestDirection: uint8(InterestDirection.KEEP),
            projectLimitBps: 2500
        });
        vm.prank(alice);
        address second = factory.createMandate(other, _kyc(kycKey, alice, other, 1));

        assertTrue(first != second);
        assertTrue(factory.isEscrowOf(alice, first) && factory.isEscrowOf(alice, second));
    }

    function test_creation_rejects_out_of_range_params() public {
        ImmutableParamsV1 memory badDir = ImmutableParamsV1({ interestDirection: 3, projectLimitBps: 1000 });
        vm.expectRevert(abi.encodeWithSelector(MandateFactory.BadInterestDirection.selector, uint8(3)));
        vm.prank(alice);
        factory.createMandate(badDir, _kyc(kycKey, alice, badDir, 1));

        ImmutableParamsV1 memory badBps = ImmutableParamsV1({ interestDirection: 0, projectLimitBps: 10001 });
        vm.expectRevert(abi.encodeWithSelector(MandateFactory.BadProjectLimitBps.selector, uint16(10001)));
        vm.prank(alice);
        factory.createMandate(badBps, _kyc(kycKey, alice, badBps, 1));
    }

    // ── isEscrowOf ──────────────────────────────────────────────────────────────

    function test_isEscrowOf_only_for_the_real_owner() public {
        vm.prank(alice);
        address escrow = factory.createMandate(params, _kyc(kycKey, alice, params, 1));

        assertTrue(factory.isEscrowOf(alice, escrow));
        assertFalse(factory.isEscrowOf(bob, escrow), "another owner derives another address");
    }

    /// A mandate address is known before it exists, so a pre-flight call must answer, not revert.
    function test_isEscrowOf_is_false_on_an_address_with_no_code() public view {
        address predicted = factory.predictMandateAddress(alice, _paramsHash(params), 1);
        assertEq(predicted.code.length, 0, "not created yet");
        assertFalse(factory.isEscrowOf(alice, predicted));
    }

    /// A forgery can report any version and paramsHash it likes; the address is the proof.
    function test_isEscrowOf_is_false_for_a_contract_that_lies_about_itself() public {
        vm.prank(alice);
        address real = factory.createMandate(params, _kyc(kycKey, alice, params, 1));

        LyingEscrow fake = new LyingEscrow(1, _paramsHash(params));
        assertFalse(factory.isEscrowOf(alice, address(fake)));
        assertTrue(factory.isEscrowOf(alice, real), "the real one still passes");
    }

    /// A genuine clone of the same implementation, deployed with someone else's salt.
    function test_isEscrowOf_is_false_for_a_clone_created_outside_the_factory() public {
        address rogue = Clones.cloneDeterministic(address(implV1), keccak256("mine"));
        MandateEscrowV1(rogue).initialize(alice, params);

        assertEq(MandateEscrowV1(rogue).owner(), alice, "it really is alice's escrow by its own storage");
        assertFalse(factory.isEscrowOf(alice, rogue), "but not one this factory issued");
    }

    function test_isEscrowOf_is_false_for_a_plain_contract() public view {
        assertFalse(factory.isEscrowOf(alice, address(factory)));
    }

    // ── version registry ────────────────────────────────────────────────────────

    /// Existing clones are immutable, so a new implementation changes nothing for them.
    function test_registering_a_new_version_leaves_old_mandates_alone() public {
        vm.prank(alice);
        address escrow = factory.createMandate(params, _kyc(kycKey, alice, params, 1));

        EscrowV2 implV2 = new EscrowV2();
        factory.registerImplementation(2, address(implV2));

        assertEq(factory.latestVersion(), 2);
        assertTrue(factory.isEscrowOf(alice, escrow), "still verifiable under version 1");
        assertEq(MandateEscrowV1(escrow).owner(), alice);
    }

    /// Without this check the mandate is still created, reports version 1, and then fails
    /// isEscrowOf forever — its payout routes would never pass the ownership check.
    function test_implementation_must_report_the_version_it_is_registered_under() public {
        vm.expectRevert(
            abi.encodeWithSelector(MandateFactory.VersionMismatch.selector, uint16(2), uint16(1))
        );
        factory.registerImplementation(2, address(implV1));
    }

    /// Zero is the registry's "nothing here" value, so it can never be a real version.
    function test_version_zero_is_rejected() public {
        vm.expectRevert(MandateFactory.ZeroVersion.selector);
        factory.registerImplementation(0, address(implV1));
    }

    /// Strictly increasing, so a number can never be reused. That matters beyond tidiness: the
    /// implementation is part of every address derived under a version, and re-pointing one would
    /// orphan every escrow already created under it.
    function test_versions_only_move_forward_and_are_never_reused() public {
        address twin = address(new EscrowV1Twin());
        vm.expectRevert(abi.encodeWithSelector(MandateFactory.VersionNotNewer.selector, uint16(1), uint16(1)));
        factory.registerImplementation(1, twin);

        factory.registerImplementation(5, address(new EscrowV5()));
        address v3 = address(new EscrowV3());
        vm.expectRevert(abi.encodeWithSelector(MandateFactory.VersionNotNewer.selector, uint16(3), uint16(5)));
        factory.registerImplementation(3, v3);
    }

    function test_registry_is_owner_only_and_rejects_codeless() public {
        vm.expectRevert(
            abi.encodeWithSelector(MandateFactory.ImplementationHasNoCode.selector, address(0xDEAD))
        );
        factory.registerImplementation(2, address(0xDEAD));

        // the zero address lands in the same check — it has no code either
        vm.expectRevert(
            abi.encodeWithSelector(MandateFactory.ImplementationHasNoCode.selector, address(0))
        );
        factory.registerImplementation(2, address(0));

        address v2 = address(new EscrowV2());
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice)
        );
        factory.registerImplementation(2, v2);
    }

    // ── signer rotation ─────────────────────────────────────────────────────────

    function test_rotating_the_signer_invalidates_the_previous_key() public {
        uint256 newKey = 0x5161;
        factory.setKycSigner(vm.addr(newKey));

        vm.expectRevert(MandateFactory.NotKycSigner.selector);
        vm.prank(alice);
        factory.createMandate(params, _kyc(kycKey, alice, params, 1));

        vm.prank(alice);
        factory.createMandate(params, _kyc(newKey, alice, params, 1));
    }

    function test_setKycSigner_is_owner_only() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice)
        );
        factory.setKycSigner(bob);
    }
}
