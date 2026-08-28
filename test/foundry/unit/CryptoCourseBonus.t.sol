// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {CryptoCourseBonus} from "../../../contracts/crypto-course-bonus/CryptoCourseBonus.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CryptoCourseBonusTest is Setup {
    CryptoCourseBonus public bonus;

    uint256 constant COURSE_A = 1;
    uint256 constant COURSE_B = 2;
    uint256 constant COURSE_UNKNOWN = 99;

    uint256 constant AMOUNT_A = 15e6;
    uint256 constant AMOUNT_B = 15e6;
    uint256 constant SEED = 1_000e6;

    address user1;
    address user2;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        CryptoCourseBonus impl = new CryptoCourseBonus();
        bytes memory data = abi.encodeCall(CryptoCourseBonus.initialize, (address(usdc), backend));
        bonus = CryptoCourseBonus(address(new ERC1967Proxy(address(impl), data)));

        bonus.setCourseAmount(COURSE_A, AMOUNT_A);
        bonus.setCourseAmount(COURSE_B, AMOUNT_B);
        vm.stopPrank();

        usdc.mint(address(bonus), SEED);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
    }

    /// @dev Builds the claim signature exactly as the backend must: EIP-191 over
    ///      keccak256(user, courseId, contract, chainid). Every argument is a parameter so the
    ///      negative tests can vary one field at a time.
    function _sign(address _user, uint256 _courseId, address _contract, uint256 _chainId, uint256 _pk)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 inner = keccak256(abi.encodePacked(_user, _courseId, _contract, _chainId));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign(address _user, uint256 _courseId) internal view returns (bytes memory) {
        return _sign(_user, _courseId, address(bonus), block.chainid, backendPk);
    }

    // ── initialize ──

    function test_initialize_setsValues() public view {
        assertEq(address(bonus.usdc()), address(usdc));
        assertEq(bonus.trustedSigner(), backend);
        assertEq(bonus.courseAmount(COURSE_A), AMOUNT_A);
        assertFalse(bonus.killSwitch());
    }

    function test_initialize_revert_zeroUsdc() public {
        CryptoCourseBonus impl = new CryptoCourseBonus();
        bytes memory data = abi.encodeCall(CryptoCourseBonus.initialize, (address(0), backend));
        vm.expectRevert("Invalid usdc");
        new ERC1967Proxy(address(impl), data);
    }

    function test_initialize_revert_zeroSigner() public {
        CryptoCourseBonus impl = new CryptoCourseBonus();
        bytes memory data = abi.encodeCall(CryptoCourseBonus.initialize, (address(usdc), address(0)));
        vm.expectRevert("Invalid trustedSigner");
        new ERC1967Proxy(address(impl), data);
    }

    // ── claim: happy path ──

    function test_claim_success() public {
        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));

        assertEq(usdc.balanceOf(user1), AMOUNT_A);
        assertTrue(bonus.isClaimed(user1, COURSE_A));
        assertEq(bonus.totalPaid(), AMOUNT_A);
        assertEq(bonus.totalBonusCount(), 1);
    }

    /// The whole point of keying uniqueness on the pair: a second course is still payable after the
    /// first. With a per-wallet flag this test would fail.
    function test_claim_secondCoursePaysAfterFirst() public {
        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
        vm.prank(user1);
        bonus.claim(COURSE_B, _sign(user1, COURSE_B));

        assertEq(usdc.balanceOf(user1), AMOUNT_A + AMOUNT_B);
        assertEq(bonus.totalBonusCount(), 2);
        assertTrue(bonus.isClaimed(user1, COURSE_A));
        assertTrue(bonus.isClaimed(user1, COURSE_B));
    }

    function test_claim_twoUsersSameCourse() public {
        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
        vm.prank(user2);
        bonus.claim(COURSE_A, _sign(user2, COURSE_A));

        assertEq(usdc.balanceOf(user1), AMOUNT_A);
        assertEq(usdc.balanceOf(user2), AMOUNT_A);
        assertEq(bonus.totalBonusCount(), 2);
    }

    function test_claim_emitsEventWithCourseId() public {
        vm.expectEmit(true, true, true, true, address(bonus));
        emit CryptoCourseBonus.BonusClaimed(user1, COURSE_A, AMOUNT_A);

        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
    }

    /// The amount is read at claim time, so a voucher issued before a repricing pays the new amount.
    /// Pinned because it is the reason the amount is not part of the signed data.
    function test_claim_paysCurrentAmountNotTheOneAtIssuance() public {
        bytes memory sig = _sign(user1, COURSE_A);

        vm.prank(owner);
        bonus.setCourseAmount(COURSE_A, 25e6);

        vm.prank(user1);
        bonus.claim(COURSE_A, sig);
        assertEq(usdc.balanceOf(user1), 25e6);
    }

    // ── claim: once-only and configuration ──

    function test_claim_revert_sameCourseTwice() public {
        bytes memory sig = _sign(user1, COURSE_A);

        vm.prank(user1);
        bonus.claim(COURSE_A, sig);

        vm.prank(user1);
        vm.expectRevert("Already claimed");
        bonus.claim(COURSE_A, sig);
    }

    /// A zero amount is the single "not payable" state, whether the course was never configured or
    /// was retired by zeroing it. Retiring is the targeted revocation: vouchers already issued for
    /// that course die, other courses keep working.
    function test_claim_revert_unconfiguredOrRetiredCourse() public {
        // never configured
        vm.prank(user1);
        vm.expectRevert("Course not configured");
        bonus.claim(COURSE_UNKNOWN, _sign(user1, COURSE_UNKNOWN));

        // configured, then zeroed — same state
        bytes memory sig = _sign(user1, COURSE_A);

        vm.prank(owner);
        bonus.setCourseAmount(COURSE_A, 0);

        vm.prank(user1);
        vm.expectRevert("Course not configured");
        bonus.claim(COURSE_A, sig);

        vm.prank(user1);
        bonus.claim(COURSE_B, _sign(user1, COURSE_B));
        assertEq(usdc.balanceOf(user1), AMOUNT_B);
    }

    function test_claim_revert_insufficientBalance() public {
        // read the balance before the prank: an external call in an argument would consume it
        uint256 bal = usdc.balanceOf(address(bonus));
        vm.prank(owner);
        bonus.withdraw(address(usdc), bal, owner);

        vm.prank(user1);
        vm.expectRevert("Insufficient USDC balance");
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
    }

    // ── claim: signature binding. Each test varies one preimage field ──

    function test_claim_revert_foreignSigner() public {
        (, uint256 attackerPk) = makeAddrAndKey("attackerSigner");
        bytes memory sig = _sign(user1, COURSE_A, address(bonus), block.chainid, attackerPk);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(COURSE_A, sig);
    }

    function test_claim_revert_signatureIssuedToAnotherUser() public {
        bytes memory sig = _sign(user1, COURSE_A);

        vm.prank(user2);
        vm.expectRevert("Not trusted signer");
        bonus.claim(COURSE_A, sig);
    }

    /// Without `courseId` in the preimage a voucher for the cheap course would unlock the expensive
    /// one. This is the field the previous version of the contract did not have.
    function test_claim_revert_signatureIssuedForAnotherCourse() public {
        bytes memory sig = _sign(user1, COURSE_A);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(COURSE_B, sig);
    }

    function test_claim_revert_signatureForAnotherContract() public {
        bytes memory sig = _sign(user1, COURSE_A, makeAddr("otherContract"), block.chainid, backendPk);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(COURSE_A, sig);
    }

    /// Guards the testnet-to-mainnet replay: same signer, same contract address, different chain.
    function test_claim_revert_signatureFromAnotherChain() public {
        bytes memory sig = _sign(user1, COURSE_A, address(bonus), block.chainid + 1, backendPk);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(COURSE_A, sig);
    }

    function test_claim_revert_malformedSignature() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", 4));
        bonus.claim(COURSE_A, hex"deadbeef");
    }

    /// Rotating the signer is the blunt revocation: every outstanding voucher dies at once.
    function test_claim_revert_afterSignerRotation() public {
        bytes memory sig = _sign(user1, COURSE_A);

        (address newSigner,) = makeAddrAndKey("newSigner");
        vm.prank(owner);
        bonus.setTrustedSigner(newSigner);

        vm.prank(user1);
        vm.expectRevert("Not trusted signer");
        bonus.claim(COURSE_A, sig);
    }

    // ── admin ──

    function test_setCourseAmount_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(bonus));
        emit CryptoCourseBonus.CourseAmountSet(COURSE_UNKNOWN, 7e6);

        vm.prank(owner);
        bonus.setCourseAmount(COURSE_UNKNOWN, 7e6);
        assertEq(bonus.courseAmount(COURSE_UNKNOWN), 7e6);
    }

    function test_setCourseAmounts_batch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 10; amounts[0] = 1e6;
        ids[1] = 11; amounts[1] = 2e6;

        vm.prank(owner);
        bonus.setCourseAmounts(ids, amounts);

        assertEq(bonus.courseAmount(10), 1e6);
        assertEq(bonus.courseAmount(11), 2e6);
    }

    function test_setCourseAmounts_revert_lengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(owner);
        vm.expectRevert("Length mismatch");
        bonus.setCourseAmounts(ids, amounts);
    }

    function test_setCourseAmount_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.setCourseAmount(COURSE_A, 50e6);
    }

    function test_setTrustedSigner_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert("Invalid trustedSigner");
        bonus.setTrustedSigner(address(0));
    }

    function test_setTrustedSigner_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.setTrustedSigner(attacker);
    }

    function test_setKillSwitch_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.setKillSwitch(true);
    }

    function test_withdraw_success() public {
        address recipient = makeAddr("recipient");
        uint256 bal = usdc.balanceOf(address(bonus));

        vm.prank(owner);
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
        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        bonus.withdraw(address(usdc), 1e6, address(0));
    }

    function test_setUsdc_success() public {
        MockUSDC other = new MockUSDC();

        vm.expectEmit(true, true, true, true, address(bonus));
        emit CryptoCourseBonus.UsdcSet(address(other));

        vm.prank(owner);
        bonus.setUsdc(address(other));
        assertEq(address(bonus.usdc()), address(other));
    }

    function test_setUsdc_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert("Invalid usdc");
        bonus.setUsdc(address(0));
    }

    function test_setUsdc_revert_notOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bonus.setUsdc(address(usdc));
    }

    function test_setKillSwitch_stopsAndResumes() public {
        vm.prank(owner);
        bonus.setKillSwitch(true);
        assertTrue(bonus.killSwitch());

        vm.prank(user1);
        vm.expectRevert("Kill switch is active");
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));

        vm.prank(owner);
        bonus.setKillSwitch(false);
        assertFalse(bonus.killSwitch());

        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
        assertEq(usdc.balanceOf(user1), AMOUNT_A);
    }

    /// Balance exactly equal to the amount must pass — the guard is `>=`, not `>`.
    function test_claim_exactBalanceIsEnough() public {
        uint256 bal = usdc.balanceOf(address(bonus));
        vm.prank(owner);
        bonus.withdraw(address(usdc), bal - AMOUNT_A, owner);
        assertEq(usdc.balanceOf(address(bonus)), AMOUNT_A);

        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
        assertEq(usdc.balanceOf(address(bonus)), 0);
    }

    // ── proxy ──

    function test_initialize_revert_calledTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        bonus.initialize(address(usdc), backend);
    }

    // ── views ──

    function test_isClaimable() public {
        assertTrue(bonus.isClaimable(user1, COURSE_A));
        assertFalse(bonus.isClaimable(user1, COURSE_UNKNOWN), "not configured");

        vm.prank(user1);
        bonus.claim(COURSE_A, _sign(user1, COURSE_A));
        assertFalse(bonus.isClaimable(user1, COURSE_A), "already claimed");
        assertTrue(bonus.isClaimable(user2, COURSE_A), "another wallet");

        vm.prank(owner);
        bonus.setKillSwitch(true);
        assertFalse(bonus.isClaimable(user2, COURSE_A), "kill switch");
    }

}
