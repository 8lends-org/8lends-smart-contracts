// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {CryptoCourseBonus} from "../../../contracts/bonus/CryptoCourseBonus.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract CryptoCourseBonusTest is Setup {
    CryptoCourseBonus public bonus;

    uint256 constant COURSE_A = 1;
    uint256 constant COURSE_B = 2;
    uint256 constant COURSE_UNKNOWN = 99;

    uint256 constant CASH_A = 15e6;
    uint256 constant VOUCHER_A = 60e6;
    uint256 constant CASH_B = 10e6;
    uint256 constant SEED = 1_000e6;

    address user1;
    address user2;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        CryptoCourseBonus impl = new CryptoCourseBonus();
        bytes memory data = abi.encodeCall(CryptoCourseBonus.initialize, (address(managerRegistry), address(usdc)));
        bonus = CryptoCourseBonus(address(new ERC1967Proxy(address(impl), data)));

        bonus.setCashAmount(COURSE_A, CASH_A);
        bonus.setVoucherAmount(COURSE_A, VOUCHER_A);
        bonus.setCashAmount(COURSE_B, CASH_B);
        vm.stopPrank();

        usdc.mint(address(bonus), SEED);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
    }

    // ── initialize ──────────────────────────────────────────────────────────────

    function test_initialize_setsValues() public view {
        assertEq(address(bonus.usdc()), address(usdc));
        assertEq(address(bonus.managerRegistry()), address(managerRegistry));
        assertEq(bonus.cashAmount(COURSE_A), CASH_A);
        assertEq(bonus.voucherAmount(COURSE_A), VOUCHER_A);
    }

    function test_initialize_revert_zeroAddresses() public {
        CryptoCourseBonus impl = new CryptoCourseBonus();

        vm.expectRevert(CryptoCourseBonus.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(CryptoCourseBonus.initialize, (address(0), address(usdc))));

        vm.expectRevert(CryptoCourseBonus.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(CryptoCourseBonus.initialize, (address(managerRegistry), address(0))));
    }

    // ── payouts ─────────────────────────────────────────────────────────────────

    function test_cash_paysTheUserNotTheCaller() public {
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        assertEq(usdc.balanceOf(user1), CASH_A, "user must receive");
        assertEq(usdc.balanceOf(operator), 0, "the caller must receive nothing");
        assertEq(usdc.balanceOf(address(bonus)), SEED - CASH_A);
    }

    function test_voucher_paysItsOwnLargerAmount() public {
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A);
        assertEq(usdc.balanceOf(user1), VOUCHER_A, "voucher amount is independent of the cash one");
    }

    function test_events_carryUserCourseAndAmount() public {
        vm.expectEmit(true, true, false, true, address(bonus));
        emit CryptoCourseBonus.CashBonusPaid(user1, COURSE_A, CASH_A);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        vm.expectEmit(true, true, false, true, address(bonus));
        emit CryptoCourseBonus.VoucherBonusPaid(user2, COURSE_A, VOUCHER_A);
        vm.prank(operator);
        bonus.sendVoucherBonus(user2, COURSE_A);
    }

    // ── once per (wallet, course), in either form ────────────────────────────────

    function test_revert_sameWalletAndCourseTwice() public {
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);
    }

    function test_cashClosesTheVoucherForTheSameCourse() public {
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A);
    }

    function test_voucherClosesTheCashForTheSameCourse() public {
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A);

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);
    }

    function test_otherCoursesAndOtherWalletsStayOpen() public {
        vm.startPrank(operator);
        bonus.sendCashBonus(user1, COURSE_A);
        bonus.sendCashBonus(user1, COURSE_B); // same wallet, other course
        bonus.sendCashBonus(user2, COURSE_A); // other wallet, same course
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), CASH_A + CASH_B);
        assertEq(usdc.balanceOf(user2), CASH_A);
        assertEq(bonus.totalBonusCount(), 3);
        assertEq(bonus.totalPaid(), CASH_A + CASH_B + CASH_A);
    }

    // ── who may call ────────────────────────────────────────────────────────────

    function test_revert_callerIsNotOperator() public {
        vm.expectRevert(CryptoCourseBonus.NotOperator.selector);
        vm.prank(user1);
        bonus.sendCashBonus(user1, COURSE_A);

        // Not even the owner: paying is the operator's job, and the owner has withdraw for the rest.
        vm.expectRevert(CryptoCourseBonus.NotOperator.selector);
        vm.prank(owner);
        bonus.sendVoucherBonus(user1, COURSE_A);
    }

    /// @dev Revocation lives in the registry, not here: one call takes the key out of every
    ///      operator-gated contract at once.
    function test_revokingTheOperatorRoleStopsPayouts() public {
        vm.prank(owner);
        managerRegistry.setOperatorStatus(operator, false);

        vm.expectRevert(CryptoCourseBonus.NotOperator.selector);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        address other = makeAddr("otherOperator");
        vm.prank(owner);
        managerRegistry.setOperatorStatus(other, true);
        vm.prank(other);
        bonus.sendCashBonus(user1, COURSE_A);
        assertEq(usdc.balanceOf(user1), CASH_A);
    }

    // ── unknown or retired course ───────────────────────────────────────────────

    function test_revert_unknownCourse() public {
        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.RewardNotConfigured.selector, COURSE_UNKNOWN)
        );
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_UNKNOWN);
    }

    function test_revert_voucherNotConfiguredWhileCashIs() public {
        // COURSE_B has a cash amount only — the two rewards are configured independently.
        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.RewardNotConfigured.selector, COURSE_B)
        );
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_B);
    }

    // ── balance ─────────────────────────────────────────────────────────────────

    /// @dev Walks the boundary rather than testing an empty balance twice: one wei short reverts,
    ///      exactly the amount goes through. That is what pins `<` and would catch a `<=`.
    function test_balanceBoundary() public {
        vm.prank(owner);
        bonus.withdraw(address(usdc), SEED - (CASH_A - 1), owner);

        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.InsufficientBalance.selector, CASH_A, CASH_A - 1)
        );
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        usdc.mint(address(bonus), 1); // exactly CASH_A on the balance now
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);
        assertEq(usdc.balanceOf(user1), CASH_A);
        assertEq(usdc.balanceOf(address(bonus)), 0, "the last wei is spendable");
    }

    // ── batch ───────────────────────────────────────────────────────────────────

    function test_batch_paysEveryPair() public {
        address[] memory users = new address[](2);
        uint256[] memory courses = new uint256[](2);
        users[0] = user1;
        courses[0] = COURSE_A;
        users[1] = user2;
        courses[1] = COURSE_A;

        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, courses);

        assertEq(usdc.balanceOf(user1), VOUCHER_A);
        assertEq(usdc.balanceOf(user2), VOUCHER_A);
        assertEq(bonus.totalBonusCount(), 2);
    }

    function test_batch_isAllOrNothing() public {
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A); // user1 is already paid

        address[] memory users = new address[](2);
        uint256[] memory courses = new uint256[](2);
        users[0] = user2;
        courses[0] = COURSE_A;
        users[1] = user1; // this one reverts, so user2 must not be paid either
        courses[1] = COURSE_A;

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, courses);

        assertEq(usdc.balanceOf(user2), 0, "nothing lands when one pair fails");
    }

    function test_batch_revert_lengthMismatchAndEmpty() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory courses = new uint256[](2);

        vm.expectRevert(CryptoCourseBonus.LengthMismatch.selector);
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, courses);

        vm.expectRevert(CryptoCourseBonus.EmptyBatch.selector);
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(new address[](0), new uint256[](0));
    }

    // ── kill switch and zero recipient ──────────────────────────────────────────

    function test_revert_killSwitchStopsBothRewards() public {
        vm.prank(owner);
        bonus.setKillSwitch(true);

        vm.expectRevert(CryptoCourseBonus.PayoutsStopped.selector);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A);

        vm.expectRevert(CryptoCourseBonus.PayoutsStopped.selector);
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A);
    }

    function test_revert_zeroRecipient() public {
        vm.expectRevert(CryptoCourseBonus.ZeroAddress.selector);
        vm.prank(operator);
        bonus.sendCashBonus(address(0), COURSE_A);
    }

    // ── admin ───────────────────────────────────────────────────────────────────

    function test_setters_areOwnerOnly() public {
        bytes memory denied =
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1);

        vm.startPrank(user1);
        vm.expectRevert(denied);
        bonus.setCashAmount(COURSE_A, 1);
        vm.expectRevert(denied);
        bonus.setVoucherAmount(COURSE_A, 1);
        vm.expectRevert(denied);
        bonus.updateContracts(user1, user1);
        vm.expectRevert(denied);
        bonus.setKillSwitch(true);
        vm.expectRevert(denied);
        bonus.withdraw(address(usdc), 1, user1);
        vm.stopPrank();
    }
}
