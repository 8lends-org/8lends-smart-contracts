// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {CryptoCourceBonus} from "../../../contracts/crypto-cource-bonus/CryptoCourceBonus.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CryptoCourceBonusTest is Setup {
    CryptoCourceBonus public bonus;

    uint256 constant BONUS = 30e6; // 30 USDC
    address user1;
    address user2;

    function setUp() public override {
        super.setUp();

        CryptoCourceBonus impl = new CryptoCourceBonus();
        bytes memory data = abi.encodeCall(CryptoCourceBonus.initialize, (address(usdc), backend, BONUS));
        bonus = CryptoCourceBonus(address(new ERC1967Proxy(address(impl), data)));

        usdc.mint(address(bonus), 1_000e6);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
    }

    /// @notice Build the EIP-191 claim signature (as the backend does)
    function _signClaim(address _user, uint256 _pk) internal view returns (bytes memory sig) {
        bytes32 innerHash = keccak256(abi.encodePacked(_user, address(bonus), block.chainid));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, ethSignedHash);
        sig = abi.encodePacked(r, s, v);
    }

    function _signClaim(address _user) internal view returns (bytes memory sig) {
        return _signClaim(_user, backendPk);
    }

    // ── initialize ──

    function test_initialize_setsValues() public view {
        assertEq(bonus.bonusAmount(), BONUS);
        assertEq(address(bonus.usdc()), address(usdc));
        assertEq(bonus.trustedSigner(), backend);
    }

    function test_initialize_revert_zeroUsdc() public {
        CryptoCourceBonus impl = new CryptoCourceBonus();
        bytes memory data = abi.encodeCall(CryptoCourceBonus.initialize, (address(0), backend, BONUS));
        vm.expectRevert("Invalid usdc");
        new ERC1967Proxy(address(impl), data);
    }

    function test_initialize_revert_zeroSigner() public {
        CryptoCourceBonus impl = new CryptoCourceBonus();
        bytes memory data = abi.encodeCall(CryptoCourceBonus.initialize, (address(usdc), address(0), BONUS));
        vm.expectRevert("Invalid trustedSigner");
        new ERC1967Proxy(address(impl), data);
    }

    // ── claim ──

    function test_claim_success() public {
        bytes memory sig = _signClaim(user1);

        vm.prank(user1);
        bonus.claim(sig);

        assertEq(usdc.balanceOf(user1), BONUS);
        assertTrue(bonus.isClaimed(user1));
        assertEq(bonus.totalPaid(), BONUS);
        assertEq(bonus.totalBonusCount(), 1);
    }

    function test_claim_revert_doubleClaim() public {
        bytes memory sig = _signClaim(user1);

        vm.prank(user1);
        bonus.claim(sig);

        vm.prank(user1);
        vm.expectRevert("Bonus already claimed");
        bonus.claim(sig);
    }

    function test_claim_revert_wrongSigner() public {
        (, uint256 attackerPk) = makeAddrAndKey("attackerSigner");
        bytes memory sig = _signClaim(user1, attackerPk);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(sig);
    }

    function test_claim_revert_signatureForAnotherUser() public {
        bytes memory sig = _signClaim(user1);

        vm.prank(user2);
        vm.expectRevert("Not trusted signer");
        bonus.claim(sig);
    }

    function test_claim_revert_invalidSignatureLength() public {
        vm.prank(user1);
        vm.expectRevert("Invalid signature length");
        bonus.claim(hex"deadbeef");
    }

    function test_claim_revert_killSwitch() public {
        bonus.setKillSwitch(true);

        bytes memory sig = _signClaim(user1);
        vm.prank(user1);
        vm.expectRevert("Kill switch is active");
        bonus.claim(sig);
    }

    function test_claim_revert_insufficientBalance() public {
        bonus.withdraw(address(usdc), usdc.balanceOf(address(bonus)), owner);

        bytes memory sig = _signClaim(user1);
        vm.prank(user1);
        vm.expectRevert("Insufficient USDC balance");
        bonus.claim(sig);
    }

    function test_claim_afterSignerRotation_oldSigInvalid() public {
        bytes memory sig = _signClaim(user1);

        (address newSigner,) = makeAddrAndKey("newSigner");
        bonus.setTrustedSigner(newSigner);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(sig);
    }

    // ── admin ──

    function test_setBonusAmount_success() public {
        bonus.setBonusAmount(50e6);
        assertEq(bonus.bonusAmount(), 50e6);
    }

    function test_setBonusAmount_revert_zero() public {
        vm.expectRevert("Amount must be greater than 0");
        bonus.setBonusAmount(0);
    }

    function test_setBonusAmount_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.setBonusAmount(50e6);
    }

    function test_setTrustedSigner_revert_zero() public {
        vm.expectRevert("Invalid trustedSigner");
        bonus.setTrustedSigner(address(0));
    }

    function test_setTrustedSigner_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.setTrustedSigner(attacker);
    }

    function test_setKillSwitch_success() public {
        bonus.setKillSwitch(true);
        assertTrue(bonus.killSwitch());
    }

    function test_withdraw_success() public {
        address recipient = makeAddr("recipient");
        uint256 bal = usdc.balanceOf(address(bonus));

        bonus.withdraw(address(usdc), bal, recipient);

        assertEq(usdc.balanceOf(recipient), bal);
        assertEq(usdc.balanceOf(address(bonus)), 0);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.withdraw(address(usdc), 1e6, attacker);
    }

    function test_withdraw_revert_zeroRecipient() public {
        vm.expectRevert("Invalid recipient");
        bonus.withdraw(address(usdc), 1e6, address(0));
    }

    function test_getStats() public {
        bytes memory sig = _signClaim(user1);
        vm.prank(user1);
        bonus.claim(sig);

        (uint256 paid, uint256 count, uint256 balance) = bonus.getStats();
        assertEq(paid, BONUS);
        assertEq(count, 1);
        assertEq(balance, 1_000e6 - BONUS);
    }
}
