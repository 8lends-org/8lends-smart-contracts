// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { USDC } from "../../../contracts/test-tokens/usdc.sol";
import { TestERC20 } from "../../../contracts/test-tokens/testerc20.sol";

/// @dev Minimal ERC-1271 account: approves exactly one digest. Enough to prove the token accepts a
///      smart-account signature, which is the reason the bytes form exists at all.
contract SmartAccount is IERC1271 {
    bytes32 public approved;

    function approve(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return hash == approved ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract TestUSDCTest is Test {
    USDC usdc;

    uint256 payerKey = 0xA11CE;
    address payer;
    address payee = address(0xB0B);

    function setUp() public {
        USDC impl = new USDC();
        usdc = USDC(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(TestERC20.initialize, (address(this), "USD Coin", "USDC", 6))
                )
            )
        );
        payer = vm.addr(payerKey);
        usdc.mint(payer, 1_000e6);
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _receiveHash(address from, address to, uint256 value, uint256 after_, uint256 before_, bytes32 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, after_, before_, nonce)
        );
    }

    // ── EIP-712 constants ───────────────────────────────────────────────────────

    /// @dev A drift here would surface on a testnet only as an unexplained "invalid signature".
    function test_typehash_matches_circle() public view {
        assertEq(
            usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8
        );
    }

    /// The domain reads name() live, so the rename to "USD Coin" moves it.
    function test_domain_separator_follows_rename() public {
        bytes32 before_ = usdc.DOMAIN_SEPARATOR();
        usdc.rename("Something Else", "SE", 6);
        assertTrue(usdc.DOMAIN_SEPARATOR() != before_);
    }

    // ── receiveWithAuthorization ────────────────────────────────────────────────

    /// Expiry must not burn the nonce, or every abandoned signing flow would leak an intent record —
    /// the backend derives the nonce from one.
    function test_expiry_leaves_the_nonce_reusable() public {
        vm.warp(1_000);
        bytes32 nonce = keccak256("n1");

        bytes memory stale = _sign(payerKey, _receiveHash(payer, payee, 100e6, 0, block.timestamp, nonce));
        vm.expectRevert("FiatTokenV2: authorization is expired");
        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, block.timestamp, nonce, stale);
        assertFalse(usdc.authorizationState(payer, nonce), "nothing was consumed");

        uint256 fresh = block.timestamp + 1 hours;
        bytes memory resigned = _sign(payerKey, _receiveHash(payer, payee, 100e6, 0, fresh, nonce));
        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, fresh, nonce, resigned);
        assertEq(usdc.balanceOf(payee), 100e6, "the same nonce works with a new window");
    }

    /// Nonces are namespaced per payer, so two users may pick the same one.
    function test_nonces_are_per_payer() public {
        uint256 otherKey = 0xBEEF;
        address other = vm.addr(otherKey);
        usdc.mint(other, 100e6);

        bytes32 nonce = keccak256("shared");
        uint256 until_ = block.timestamp + 1 hours;

        bytes memory sigA = _sign(payerKey, _receiveHash(payer, payee, 50e6, 0, until_, nonce));
        bytes memory sigB = _sign(otherKey, _receiveHash(other, payee, 50e6, 0, until_, nonce));

        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 50e6, 0, until_, nonce, sigA);
        vm.prank(payee);
        usdc.receiveWithAuthorization(other, payee, 50e6, 0, until_, nonce, sigB);

        assertEq(usdc.balanceOf(payee), 100e6);
    }

    /// The reason the signature is bytes and not v/r/s.
    function test_smart_account_can_authorize() public {
        SmartAccount account = new SmartAccount();
        usdc.mint(address(account), 100e6);

        bytes32 nonce = keccak256("n1");
        uint256 until_ = block.timestamp + 1 hours;
        bytes32 structHash = _receiveHash(address(account), payee, 100e6, 0, until_, nonce);
        account.approve(keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));

        vm.prank(payee);
        usdc.receiveWithAuthorization(address(account), payee, 100e6, 0, until_, nonce, hex"c0ffee");
        assertEq(usdc.balanceOf(payee), 100e6);
    }

    // ── cancelAuthorization ─────────────────────────────────────────────────────

    function test_cancel_burns_the_nonce() public {
        bytes32 nonce = keccak256("n1");
        uint256 until_ = block.timestamp + 1 hours;

        bytes memory cancelSig =
            _sign(payerKey, keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), payer, nonce)));
        usdc.cancelAuthorization(payer, nonce, cancelSig);
        assertTrue(usdc.authorizationState(payer, nonce));

        bytes memory sig = _sign(payerKey, _receiveHash(payer, payee, 100e6, 0, until_, nonce));
        vm.expectRevert("FiatTokenV2: authorization is used or canceled");
        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, until_, nonce, sig);
    }

    function test_cancel_needs_the_authorizer_own_signature() public {
        bytes32 nonce = keccak256("n1");
        bytes memory wrongSig =
            _sign(0xBEEF, keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), payer, nonce)));

        vm.expectRevert("FiatTokenV2: invalid signature");
        usdc.cancelAuthorization(payer, nonce, wrongSig);
    }

    // ── blacklist ───────────────────────────────────────────────────────────────

    /// A blacklisted counterparty reverting is the intended outcome: the platform must not move
    /// money on a blocked address's behalf.
    /// @dev One message for both sides, as in the deployed FiatTokenV2_2 — the string is pinned
    ///      because a backend may match on it, and it must not differ from Base.
    function test_blacklist_blocks_both_directions() public {
        usdc.blacklist(payer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vm.prank(payer);
        usdc.transfer(payee, 1e6);

        usdc.unBlacklist(payer);
        usdc.blacklist(payee);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vm.prank(payer);
        usdc.transfer(payee, 1e6);
    }

    function test_blacklist_stops_an_authorized_pull() public {
        usdc.blacklist(payer);

        bytes32 nonce = keccak256("n1");
        uint256 until_ = block.timestamp + 1 hours;
        bytes memory sig = _sign(payerKey, _receiveHash(payer, payee, 100e6, 0, until_, nonce));

        vm.expectRevert("Blacklistable: account is blacklisted");
        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 100e6, 0, until_, nonce, sig);
    }

    function test_blacklist_is_owner_only() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        usdc.blacklist(payer);
        vm.expectRevert();
        usdc.unBlacklist(payer);
        vm.stopPrank();
    }
}
