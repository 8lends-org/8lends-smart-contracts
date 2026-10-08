// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {BTC8L} from "../../../contracts/token/BTC8L.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BTC8LTest is Test {
    BTC8L public btc;

    address admin;
    address user;
    address other;

    /// @dev A deposit identifier is a bitcoin txid, public from the moment it is broadcast.
    bytes32 constant BTC_TX = keccak256("btc-tx-of-a-real-deposit");
    bytes32 constant INTENT = keccak256("withdrawal-intent");

    uint256 constant DEPOSIT = 1e8;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        other = makeAddr("other");

        BTC8L impl = new BTC8L();
        bytes memory data = abi.encodeCall(BTC8L.initialize, (admin));
        btc = BTC8L(address(new ERC1967Proxy(address(impl), data)));
    }

    function _credit(address to, bytes32 btcTx, uint256 amount) internal {
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[] memory txs = new bytes32[](1);
        accounts[0] = to;
        amounts[0] = amount;
        txs[0] = btcTx;
        vm.prank(admin);
        btc.replenish(accounts, amounts, txs);
    }

    // ── the finding ──

    function test_spentIntentDoesNotBlockTheSameDepositId() public {
        // Someone burns against a deposit identifier published on the bitcoin network, before the
        // backend credits it.
        _credit(other, keccak256("funding-the-attacker"), 1);
        vm.prank(other);
        btc.withdraw(BTC_TX, 1);

        _credit(user, BTC_TX, DEPOSIT);
        assertEq(btc.balanceOf(user), DEPOSIT, "deposit must still be creditable");
    }

    function test_twoAddressesMayShareAnIntent() public {
        _credit(user, keccak256("d1"), DEPOSIT);
        _credit(other, keccak256("d2"), DEPOSIT);

        vm.prank(user);
        btc.withdraw(INTENT, 1);
        vm.prank(other);
        btc.withdraw(INTENT, 1);

        assertEq(btc.balanceOf(user), DEPOSIT - 1);
        assertEq(btc.balanceOf(other), DEPOSIT - 1);
    }

    function test_oneAddressCannotSpendItsIntentTwice() public {
        _credit(user, keccak256("d1"), DEPOSIT);

        vm.prank(user);
        btc.withdraw(INTENT, 1);
        assertTrue(btc.intentHashes(btc.intentKey(user, INTENT)));

        vm.prank(user);
        vm.expectRevert("BTC8L: Intent hash already used");
        btc.withdraw(INTENT, 1);
    }

    function test_zeroAmountWithdrawReverts() public {
        vm.prank(other);
        vm.expectRevert("BTC8L: Zero amount");
        btc.withdraw(INTENT, 0);
        assertFalse(btc.intentHashes(btc.intentKey(other, INTENT)), "a rejected withdraw must not spend the intent");
    }

    /// @dev The backend derives the key itself, so the encoding is part of the interface.
    function test_intentKeyIsReproducibleOffChain() public view {
        bytes32 hash = 0x1111111111111111111111111111111111111111111111111111111111111111;
        assertEq(btc.intentKey(address(0xdEaD), hash), 0xfc2b7ad5ace115924c920afd7d08e72e192ec359b9839fc2fd00cfa2a285690b);
    }

    // ── minter path ──

    function test_minterWithdrawSharesTheOwnersIntentSpace() public {
        _credit(user, keccak256("d1"), DEPOSIT);

        vm.prank(admin);
        btc.withdraw(INTENT, 1, user);

        vm.prank(user);
        vm.expectRevert("BTC8L: Intent hash already used");
        btc.withdraw(INTENT, 1);
    }

    function test_minterWithdrawIsRoleGated() public {
        _credit(user, keccak256("d1"), DEPOSIT);
        vm.prank(other);
        vm.expectRevert();
        btc.withdraw(INTENT, 1, user);
    }

    // ── replenish ──

    function test_replenishRejectsASpentIdentifier() public {
        _credit(user, BTC_TX, DEPOSIT);

        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[] memory txs = new bytes32[](1);
        accounts[0] = user;
        amounts[0] = DEPOSIT;
        txs[0] = BTC_TX;

        vm.prank(admin);
        vm.expectRevert("BTC8L: Intent hash already used");
        btc.replenish(accounts, amounts, txs);

        assertEq(btc.balanceOf(user), DEPOSIT, "a rejected batch must not credit twice");
    }

    // ── transfers stay closed ──

    function test_holdersStillCannotTransfer() public {
        _credit(user, keccak256("d1"), DEPOSIT);
        vm.prank(user);
        vm.expectRevert("BTC8L: Not authorized");
        btc.transfer(other, 1);
    }
}
