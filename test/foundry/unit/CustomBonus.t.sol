// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {CustomBonus} from "../../../contracts/custom-bonus/CustomBonus.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CustomBonusTest is Setup {
    CustomBonus public cb;

    uint8 constant TYPE_MARKETING = 1;
    uint8 constant TYPE_SUPPORT = 2;
    uint256 constant CAMPAIGN_A = 101;
    uint256 constant CAMPAIGN_B = 202;

    uint256 constant SEED = 1_000e6;
    uint256 constant AMOUNT = 15e6;

    address user1;
    address user2;
    address notOperator;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        CustomBonus impl = new CustomBonus();
        bytes memory data = abi.encodeCall(CustomBonus.initialize, (address(managerRegistry), address(usdc)));
        cb = CustomBonus(address(new ERC1967Proxy(address(impl), data)));

        usdc.mint(address(cb), SEED);
        vm.stopPrank();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        notOperator = makeAddr("notOperator");
    }

    // ── sendCustomBonus (single) ──

    function test_sendCustomBonus_success() public {
        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);

        assertEq(usdc.balanceOf(user1), AMOUNT);
        assertTrue(cb.isPaid(user1, TYPE_MARKETING, CAMPAIGN_A));
        assertEq(cb.totalPaid(), AMOUNT);
        assertEq(cb.totalBonusCount(), 1);
    }

    function test_sendCustomBonus_revert_doublePay_sameTriple() public {
        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);

        vm.prank(operator);
        vm.expectRevert("Already paid");
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
    }

    function test_sendCustomBonus_sameUser_differentCampaign_bothPaid() public {
        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);

        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_B, 20e6);

        assertEq(usdc.balanceOf(user1), AMOUNT + 20e6);
        assertEq(cb.totalBonusCount(), 2);
    }

    function test_campaignStats_trackedPerTypeAndCampaign() public {
        // (MARKETING, A): 2 payouts
        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
        vm.prank(operator);
        cb.sendCustomBonus(user2, TYPE_MARKETING, CAMPAIGN_A, 25e6);

        // (SUPPORT, A): 1 payout — same campaignId, different bonusType → separate bucket
        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_SUPPORT, CAMPAIGN_A, 5e6);

        (uint256 mktA_paid, uint256 mktA_count) = cb.getCampaignStats(TYPE_MARKETING, CAMPAIGN_A);
        assertEq(mktA_paid, AMOUNT + 25e6);
        assertEq(mktA_count, 2);

        (uint256 supA_paid, uint256 supA_count) = cb.getCampaignStats(TYPE_SUPPORT, CAMPAIGN_A);
        assertEq(supA_paid, 5e6);
        assertEq(supA_count, 1);
    }

    function test_sendCustomBonus_revert_notOperator() public {
        vm.prank(notOperator);
        vm.expectRevert("Not an operator");
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
    }

    /// A manager is a privileged address elsewhere in the protocol but must be rejected here —
    /// fails if `|| isManager` is ever added back to the guard.
    function test_sendCustomBonus_revert_managerIsNotOperator() public {
        assertTrue(managerRegistry.isManager(manager));
        assertFalse(managerRegistry.isOperator(manager));

        vm.prank(manager);
        vm.expectRevert("Not an operator");
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
    }

    /// The payout used to be `onlyOwner` and is now `onlyOperator`; the owner is not implicitly an
    /// operator. Pinned deliberately — `_amount` here is caller-supplied.
    function test_sendCustomBonus_revert_ownerIsNotOperator() public {
        assertFalse(managerRegistry.isOperator(owner));

        vm.prank(owner);
        vm.expectRevert("Not an operator");
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
    }

    function test_sendCustomBonus_revert_killSwitch() public {
        vm.prank(owner);
        cb.setKillSwitch(true);

        vm.prank(operator);
        vm.expectRevert("Kill switch is active");
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
    }

    function test_sendCustomBonus_emitsEvent_withCorrectPaymentId() public {
        bytes32 expectedPaymentId = cb.paymentIdOf(user1, TYPE_MARKETING, CAMPAIGN_A);

        vm.expectEmit(true, true, true, true);
        emit CustomBonus.CustomBonusPaid(expectedPaymentId, user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);

        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);
    }

    // ── sendCustomBonusBatch ──

    function test_batch_success() public {
        address[] memory users = new address[](3);
        uint8[] memory types = new uint8[](3);
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            users[i] = makeAddr(string.concat("u", vm.toString(i)));
            types[i] = TYPE_MARKETING;
            ids[i] = i + 1;
            amounts[i] = 10e6 + i * 1e6;
        }

        vm.prank(operator);
        cb.sendCustomBonusBatch(users, types, ids, amounts);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(usdc.balanceOf(users[i]), amounts[i]);
        }
        assertEq(cb.totalBonusCount(), 3);
    }

    function test_batch_revert_ifAnyAlreadyPaid() public {
        // pre-pay one triple
        vm.prank(operator);
        cb.sendCustomBonus(user1, TYPE_MARKETING, CAMPAIGN_A, AMOUNT);

        // batch contains the already-paid triple → entire tx reverts, no partial payouts
        address[] memory users = new address[](2);
        uint8[] memory types = new uint8[](2);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);

        users[0] = user2; types[0] = TYPE_MARKETING; ids[0] = CAMPAIGN_A; amounts[0] = 25e6;
        users[1] = user1; types[1] = TYPE_MARKETING; ids[1] = CAMPAIGN_A; amounts[1] = AMOUNT;

        vm.prank(operator);
        vm.expectRevert("Already paid");
        cb.sendCustomBonusBatch(users, types, ids, amounts);

        // user2 shouldn't have received anything — batch was atomic
        assertEq(usdc.balanceOf(user2), 0);
        assertEq(cb.totalBonusCount(), 1); // only the pre-pay counted
    }

    // ── admin ──

    function test_withdraw_owner() public {
        address recipient = makeAddr("recipient");
        uint256 bal = usdc.balanceOf(address(cb));

        vm.prank(owner);
        cb.withdraw(address(usdc), bal, recipient);

        assertEq(usdc.balanceOf(recipient), bal);
        assertEq(usdc.balanceOf(address(cb)), 0);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(notOperator);
        vm.expectRevert();
        cb.withdraw(address(usdc), 1e6, notOperator);
    }
}
