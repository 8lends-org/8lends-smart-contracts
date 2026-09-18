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

    uint256 constant MAX_CASH_A = 15e6;
    uint256 constant MAX_VOUCHER_A = 60e6;
    uint256 constant MAX_CASH_B = 10e6;
    uint256 constant SEED = 1_000e6;

    /// A typical payout: the backend computes it off-chain, so it sits below the ceiling.
    uint256 constant PART_CASH_A = 9e6;

    address user1;
    address user2;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        CryptoCourseBonus impl = new CryptoCourseBonus();
        bytes memory data = abi.encodeCall(CryptoCourseBonus.initialize, (address(managerRegistry), address(usdc)));
        bonus = CryptoCourseBonus(address(new ERC1967Proxy(address(impl), data)));

        bonus.setMaxCashAmount(COURSE_A, MAX_CASH_A);
        bonus.setMaxVoucherAmount(COURSE_A, MAX_VOUCHER_A);
        bonus.setMaxCashAmount(COURSE_B, MAX_CASH_B);
        vm.stopPrank();

        usdc.mint(address(bonus), SEED);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
    }

    // ── initialize ──────────────────────────────────────────────────────────────

    function test_initialize_setsValues() public view {
        assertEq(address(bonus.usdc()), address(usdc));
        assertEq(address(bonus.managerRegistry()), address(managerRegistry));
        assertEq(bonus.maxCashAmount(COURSE_A), MAX_CASH_A);
        assertEq(bonus.maxVoucherAmount(COURSE_A), MAX_VOUCHER_A);
    }

    function test_initialize_revert_zeroAddresses() public {
        CryptoCourseBonus impl = new CryptoCourseBonus();

        vm.expectRevert(CryptoCourseBonus.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(CryptoCourseBonus.initialize, (address(0), address(usdc))));

        vm.expectRevert(CryptoCourseBonus.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(CryptoCourseBonus.initialize, (address(managerRegistry), address(0))));
    }

    // ── payouts ─────────────────────────────────────────────────────────────────

    /// The amount comes from the caller, not from storage: the ceiling is 15, this pays 9.
    function test_cash_paysTheRequestedAmountNotTheCeiling() public {
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, PART_CASH_A);

        assertEq(usdc.balanceOf(user1), PART_CASH_A, "user must receive what was asked for");
        assertEq(usdc.balanceOf(operator), 0, "the caller must receive nothing");
        assertEq(usdc.balanceOf(address(bonus)), SEED - PART_CASH_A);
        assertEq(bonus.maxCashAmount(COURSE_A), MAX_CASH_A, "the ceiling is not consumed");
    }

    /// Both directions of the bound in one test: exactly the ceiling goes through, one wei over
    /// reverts. That is what pins `>` and would catch a `>=`.
    function test_cash_ceilingBoundary() public {
        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.AmountExceedsMax.selector, MAX_CASH_A + 1, MAX_CASH_A)
        );
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A + 1);

        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);
        assertEq(usdc.balanceOf(user1), MAX_CASH_A);
    }

    /// The two ceilings are separate, so the cash one must not bound a voucher payout.
    function test_voucher_boundByItsOwnCeiling() public {
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A, MAX_VOUCHER_A);
        assertEq(usdc.balanceOf(user1), MAX_VOUCHER_A);

        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.AmountExceedsMax.selector, MAX_VOUCHER_A, MAX_CASH_A)
        );
        vm.prank(operator);
        bonus.sendCashBonus(user2, COURSE_A, MAX_VOUCHER_A);
    }

    function test_revert_zeroAmount() public {
        vm.expectRevert(CryptoCourseBonus.ZeroAmount.selector);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, 0);
    }

    function test_events_carryUserCourseAndAmount() public {
        vm.expectEmit(true, true, false, true, address(bonus));
        emit CryptoCourseBonus.CashBonusPaid(user1, COURSE_A, PART_CASH_A);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, PART_CASH_A);

        vm.expectEmit(true, true, false, true, address(bonus));
        emit CryptoCourseBonus.VoucherBonusPaid(user2, COURSE_A, MAX_VOUCHER_A);
        vm.prank(operator);
        bonus.sendVoucherBonus(user2, COURSE_A, MAX_VOUCHER_A);
    }

    // ── once per (wallet, course), in either form ────────────────────────────────

    /// Paying below the ceiling does not leave the rest claimable — the flag is boolean, not a
    /// remaining balance, so a short first payout closes the pair for good.
    function test_revert_sameWalletAndCourseTwice() public {
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, PART_CASH_A);

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A - PART_CASH_A);
    }

    function test_cashClosesTheVoucherForTheSameCourse() public {
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, PART_CASH_A);

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A, MAX_VOUCHER_A);
    }

    function test_voucherClosesTheCashForTheSameCourse() public {
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A, MAX_VOUCHER_A);

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);
    }

    function test_otherCoursesAndOtherWalletsStayOpen() public {
        vm.startPrank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);
        bonus.sendCashBonus(user1, COURSE_B, MAX_CASH_B); // same wallet, other course
        bonus.sendCashBonus(user2, COURSE_A, PART_CASH_A); // other wallet, same course
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), MAX_CASH_A + MAX_CASH_B);
        assertEq(usdc.balanceOf(user2), PART_CASH_A);
        assertEq(bonus.totalBonusCount(), 3);
        assertEq(bonus.totalPaid(), MAX_CASH_A + MAX_CASH_B + PART_CASH_A);
    }

    // ── who may call ────────────────────────────────────────────────────────────

    function test_revert_callerIsNotOperator() public {
        vm.expectRevert(CryptoCourseBonus.NotOperator.selector);
        vm.prank(user1);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);

        // Not even the owner: paying is the operator's job, and the owner has withdraw for the rest.
        vm.expectRevert(CryptoCourseBonus.NotOperator.selector);
        vm.prank(owner);
        bonus.sendVoucherBonus(user1, COURSE_A, MAX_VOUCHER_A);
    }

    /// @dev Revocation lives in the registry, not here: one call takes the key out of every
    ///      operator-gated contract at once.
    function test_revokingTheOperatorRoleStopsPayouts() public {
        vm.prank(owner);
        managerRegistry.setOperatorStatus(operator, false);

        vm.expectRevert(CryptoCourseBonus.NotOperator.selector);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);

        address other = makeAddr("otherOperator");
        vm.prank(owner);
        managerRegistry.setOperatorStatus(other, true);
        vm.prank(other);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);
        assertEq(usdc.balanceOf(user1), MAX_CASH_A);
    }

    // ── unknown or retired course ───────────────────────────────────────────────

    function test_revert_unknownCourse() public {
        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.RewardNotConfigured.selector, COURSE_UNKNOWN)
        );
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_UNKNOWN, 1e6);
    }

    function test_revert_voucherNotConfiguredWhileCashIs() public {
        // COURSE_B has a cash ceiling only — the two rewards are configured independently.
        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.RewardNotConfigured.selector, COURSE_B)
        );
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_B, 1e6);
    }

    // ── balance ─────────────────────────────────────────────────────────────────

    /// @dev Walks the boundary rather than testing an empty balance twice: one wei short reverts,
    ///      exactly the amount goes through. That is what pins `<` and would catch a `<=`.
    function test_balanceBoundary() public {
        vm.prank(owner);
        bonus.withdraw(address(usdc), SEED - (MAX_CASH_A - 1), owner);

        vm.expectRevert(
            abi.encodeWithSelector(CryptoCourseBonus.InsufficientBalance.selector, MAX_CASH_A, MAX_CASH_A - 1)
        );
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);

        usdc.mint(address(bonus), 1); // exactly MAX_CASH_A on the balance now
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);
        assertEq(usdc.balanceOf(user1), MAX_CASH_A);
        assertEq(usdc.balanceOf(address(bonus)), 0, "the last wei is spendable");
    }

    // ── batch ───────────────────────────────────────────────────────────────────

    /// Rows carry their own amounts, which is the point of the batch: vouchers mature together but
    /// are not worth the same.
    function test_batch_paysEveryRowItsOwnAmount() public {
        address[] memory users = new address[](2);
        uint256[] memory courses = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        courses[0] = COURSE_A;
        amounts[0] = MAX_VOUCHER_A;
        users[1] = user2;
        courses[1] = COURSE_A;
        amounts[1] = MAX_VOUCHER_A / 3;

        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, courses, amounts);

        assertEq(usdc.balanceOf(user1), MAX_VOUCHER_A);
        assertEq(usdc.balanceOf(user2), MAX_VOUCHER_A / 3);
        assertEq(bonus.totalBonusCount(), 2);
    }

    function test_batch_isAllOrNothing() public {
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A, MAX_VOUCHER_A); // user1 is already paid

        address[] memory users = new address[](2);
        uint256[] memory courses = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user2;
        courses[0] = COURSE_A;
        amounts[0] = MAX_VOUCHER_A;
        users[1] = user1; // this one reverts, so user2 must not be paid either
        courses[1] = COURSE_A;
        amounts[1] = MAX_VOUCHER_A;

        vm.expectRevert(abi.encodeWithSelector(CryptoCourseBonus.AlreadyPaid.selector, user1, COURSE_A));
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, courses, amounts);

        assertEq(usdc.balanceOf(user2), 0, "nothing lands when one row fails");
    }

    function test_batch_revert_lengthMismatchAndEmpty() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        vm.expectRevert(CryptoCourseBonus.LengthMismatch.selector);
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, new uint256[](2), new uint256[](1));

        // The amounts array is checked too, not only courses against users.
        vm.expectRevert(CryptoCourseBonus.LengthMismatch.selector);
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(users, new uint256[](1), new uint256[](2));

        vm.expectRevert(CryptoCourseBonus.EmptyBatch.selector);
        vm.prank(operator);
        bonus.sendVoucherBonusBatch(new address[](0), new uint256[](0), new uint256[](0));
    }

    // ── kill switch and zero recipient ──────────────────────────────────────────

    function test_revert_killSwitchStopsBothRewards() public {
        vm.prank(owner);
        bonus.setKillSwitch(true);

        vm.expectRevert(CryptoCourseBonus.PayoutsStopped.selector);
        vm.prank(operator);
        bonus.sendCashBonus(user1, COURSE_A, MAX_CASH_A);

        vm.expectRevert(CryptoCourseBonus.PayoutsStopped.selector);
        vm.prank(operator);
        bonus.sendVoucherBonus(user1, COURSE_A, MAX_VOUCHER_A);
    }

    function test_revert_zeroRecipient() public {
        vm.expectRevert(CryptoCourseBonus.ZeroAddress.selector);
        vm.prank(operator);
        bonus.sendCashBonus(address(0), COURSE_A, MAX_CASH_A);
    }

    // ── admin ───────────────────────────────────────────────────────────────────

    function test_setters_areOwnerOnly() public {
        bytes memory denied =
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1);

        vm.startPrank(user1);
        vm.expectRevert(denied);
        bonus.setMaxCashAmount(COURSE_A, 1);
        vm.expectRevert(denied);
        bonus.setMaxVoucherAmount(COURSE_A, 1);
        vm.expectRevert(denied);
        bonus.updateContracts(user1, user1);
        vm.expectRevert(denied);
        bonus.setKillSwitch(true);
        vm.expectRevert(denied);
        bonus.withdraw(address(usdc), 1, user1);
        vm.stopPrank();
    }
}
