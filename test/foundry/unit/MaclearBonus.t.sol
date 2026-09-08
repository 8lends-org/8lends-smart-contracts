// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {MaclearBonus} from "../../../contracts/bonus/MaclearBonus.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MaclearBonusTest is Setup {
    MaclearBonus public maclear;

    uint256 constant BONUS = 20e6; // 20 USDC
    address user1;
    address user2;
    address notManager;

    function setUp() public override {
        super.setUp();

        MaclearBonus impl = new MaclearBonus();
        bytes memory data = abi.encodeCall(MaclearBonus.initialize, (address(managerRegistry), address(usdc), BONUS));
        maclear = MaclearBonus(address(new ERC1967Proxy(address(impl), data)));

        usdc.mint(address(maclear), 1_000e6);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        notManager = makeAddr("notManager");
    }

    // ── initialize ──

    function test_initialize_setsBonusAmount() public view {
        assertEq(maclear.bonusAmount(), BONUS);
        assertEq(address(maclear.usdc()), address(usdc));
        assertEq(address(maclear.managerRegistry()), address(managerRegistry));
    }

    function test_initialize_revert_zeroManager() public {
        MaclearBonus impl = new MaclearBonus();
        bytes memory data = abi.encodeCall(MaclearBonus.initialize, (address(0), address(usdc), BONUS));
        vm.expectRevert("Invalid managerRegistry");
        new ERC1967Proxy(address(impl), data);
    }

    function test_initialize_revert_zeroUsdc() public {
        MaclearBonus impl = new MaclearBonus();
        bytes memory data = abi.encodeCall(MaclearBonus.initialize, (address(managerRegistry), address(0), BONUS));
        vm.expectRevert("Invalid usdc");
        new ERC1967Proxy(address(impl), data);
    }

    // ── sendBonus ──

    function test_sendBonus_success() public {
        vm.prank(manager);
        maclear.sendBonus(user1);

        assertEq(usdc.balanceOf(user1), BONUS);
        assertTrue(maclear.isClaimed(user1));
        assertEq(maclear.totalPaid(), BONUS);
        assertEq(maclear.totalBonusCount(), 1);
    }

    function test_sendBonus_revert_doubleClaim() public {
        vm.prank(manager);
        maclear.sendBonus(user1);

        vm.prank(manager);
        vm.expectRevert("Bonus already claimed");
        maclear.sendBonus(user1);
    }

    function test_sendBonus_revert_notManager() public {
        vm.prank(notManager);
        vm.expectRevert("Not a manager");
        maclear.sendBonus(user1);
    }

    function test_sendBonus_revert_killSwitch() public {
        maclear.setKillSwitch(true);

        vm.prank(manager);
        vm.expectRevert("Kill switch is active");
        maclear.sendBonus(user1);
    }

    function test_sendBonus_revert_zeroAddress() public {
        vm.prank(manager);
        vm.expectRevert("Invalid address");
        maclear.sendBonus(address(0));
    }

    function test_sendBonus_revert_insufficientBalance() public {
        maclear.withdraw(address(usdc), usdc.balanceOf(address(maclear)), owner);

        vm.prank(manager);
        vm.expectRevert("Insufficient USDC balance");
        maclear.sendBonus(user1);
    }

    // ── sendBonusBatch ──

    function test_sendBonusBatch_skipsClaimed() public {
        vm.prank(manager);
        maclear.sendBonus(user1); // pre-claim user1

        address[] memory users = new address[](3);
        users[0] = user1; // already claimed → skipped
        users[1] = user2;
        users[2] = makeAddr("user3");

        vm.prank(manager);
        maclear.sendBonusBatch(users);

        assertEq(usdc.balanceOf(user1), BONUS, "user1 not double-paid");
        assertEq(usdc.balanceOf(user2), BONUS);
        assertEq(maclear.totalBonusCount(), 3); // user1 (single) + user2 + user3
    }

    function test_sendBonusBatch_revert_empty() public {
        address[] memory users = new address[](0);
        vm.prank(manager);
        vm.expectRevert("Empty array");
        maclear.sendBonusBatch(users);
    }

    function test_sendBonusBatch_revert_tooMany() public {
        address[] memory users = new address[](201);
        vm.prank(manager);
        vm.expectRevert("Too many users");
        maclear.sendBonusBatch(users);
    }

    // ── admin ──

    function test_setBonusAmount_success() public {
        maclear.setBonusAmount(25e6);
        assertEq(maclear.bonusAmount(), 25e6);
    }

    function test_setBonusAmount_revert_zero() public {
        vm.expectRevert("Amount must be greater than 0");
        maclear.setBonusAmount(0);
    }

    function test_setBonusAmount_revert_notOwner() public {
        vm.prank(notManager);
        vm.expectRevert();
        maclear.setBonusAmount(25e6);
    }

    function test_setKillSwitch_success() public {
        maclear.setKillSwitch(true);
        assertTrue(maclear.killSwitch());
    }

    function test_withdraw_success() public {
        address recipient = makeAddr("recipient");
        uint256 bal = usdc.balanceOf(address(maclear));
        maclear.withdraw(address(usdc), bal, recipient);
        assertEq(usdc.balanceOf(recipient), bal);
        assertEq(usdc.balanceOf(address(maclear)), 0);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(notManager);
        vm.expectRevert();
        maclear.withdraw(address(usdc), 1e6, notManager);
    }

    function test_withdraw_revert_zeroRecipient() public {
        vm.expectRevert("Invalid recipient");
        maclear.withdraw(address(usdc), 1e6, address(0));
    }

    function test_getStats() public {
        vm.prank(manager);
        maclear.sendBonus(user1);

        (uint256 paid, uint256 count, uint256 balance) = maclear.getStats();
        assertEq(paid, BONUS);
        assertEq(count, 1);
        assertEq(balance, 1_000e6 - BONUS);
    }
}
