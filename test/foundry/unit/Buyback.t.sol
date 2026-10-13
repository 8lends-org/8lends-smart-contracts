// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {Buyback} from "../../../contracts/core/Buyback.sol";

contract BuybackTest is Setup {
    Buyback public buyback;

    address public holder;

    /// @dev $0.02 in USDC's six decimals.
    uint256 public constant PRICE = 2e4;

    /// @dev Tokens one USDC unit buys at that price: the smallest amount worth selling.
    uint256 public constant UNIT = 1e18 / PRICE;

    function setUp() public override {
        super.setUp();

        holder = makeAddr("holder");

        vm.startPrank(owner);
        {
            Buyback impl = new Buyback();
            bytes memory initData = abi.encodeCall(
                Buyback.initialize, (address(managerRegistry), address(token), address(usdc), PRICE)
            );
            buyback = Buyback(address(new ERC1967Proxy(address(impl), initData)));
        }
        // Without the mark the token refuses to move to this address at all.
        managerRegistry.setPoolStatus(address(buyback), true);
        // The slot is what lets withdraw mark its recipient.
        managerRegistry.setLimitedSellerAddress(address(buyback));

        usdc.mint(address(buyback), 10_000e6);
        token.mint(holder, 1_000e18);
        vm.stopPrank();
    }

    function _sell(uint256 amount) internal {
        vm.startPrank(holder);
        token.approve(address(buyback), amount);
        buyback.sell(amount);
        vm.stopPrank();
    }

    // ── Exchange ──

    function test_sellPaysTwoCentsPerToken() public {
        _sell(1_000e18);

        assertEq(usdc.balanceOf(holder), 20e6, "1000 tokens are $20");
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(buyback)), 1_000e18);
        assertEq(usdc.balanceOf(address(buyback)), 10_000e6 - 20e6);
    }

    function test_totalsAccumulateAcrossSellers() public {
        _sell(400e18);

        address second = makeAddr("second");
        vm.prank(owner);
        token.mint(second, 100e18);
        vm.startPrank(second);
        token.approve(address(buyback), 100e18);
        buyback.sell(100e18);
        vm.stopPrank();

        assertEq(buyback.totalBoughtTokens(), 500e18);
        assertEq(buyback.totalPaidUsdc(), 10e6);
    }

    function test_quoteMatchesWhatSellPays() public {
        uint256 expected = buyback.quote(137e18);
        _sell(137e18);
        assertEq(usdc.balanceOf(holder), expected);
        assertEq(expected, 2_740_000, "137 tokens are $2.74");
    }

    /// @dev The balance is not a whole number of cents, and still nothing is left behind.
    function test_sellingOutLeavesNothingBehind() public {
        vm.prank(owner);
        token.mint(holder, UNIT - 1);

        _sell(token.balanceOf(holder));

        assertEq(token.balanceOf(holder), 0);
        assertEq(usdc.balanceOf(holder), 20e6);
    }

    function test_sellRevertsWhenAmountPaysNothing() public {
        vm.startPrank(holder);
        token.approve(address(buyback), type(uint256).max);
        vm.expectRevert(Buyback.AmountTooSmall.selector);
        buyback.sell(UNIT - 1);
        vm.stopPrank();
    }

    // ── Running dry ──

    function test_sellRevertsWhenUsdcRunsOutAndKeepsTheTokens() public {
        vm.prank(owner);
        token.mint(holder, 1_000_000e18);

        vm.startPrank(holder);
        token.approve(address(buyback), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Buyback.NotEnoughUsdc.selector, 20_000e6, 10_000e6));
        buyback.sell(1_000_000e18);
        vm.stopPrank();

        assertEq(token.balanceOf(address(buyback)), 0, "tokens were not taken into the void");
        assertEq(usdc.balanceOf(address(buyback)), 10_000e6);
    }

    /// @dev Emptying the USDC is how the exchange window is closed: there is no separate switch.
    function test_withdrawingAllUsdcStopsTheExchange() public {
        vm.prank(owner);
        buyback.withdraw(address(usdc), owner, 10_000e6);

        vm.startPrank(holder);
        token.approve(address(buyback), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Buyback.NotEnoughUsdc.selector, 2e4, 0));
        buyback.sell(1e18);
        vm.stopPrank();
    }

    // ── Inventory ──

    function test_ownerWithdrawsBothAssets() public {
        _sell(1_000e18);

        address vault = makeAddr("vault");
        vm.startPrank(owner);
        buyback.withdraw(address(token), vault, 1_000e18);
        buyback.withdraw(address(usdc), owner, 100e6);
        vm.stopPrank();

        assertEq(token.balanceOf(vault), 1_000e18);
        assertEq(usdc.balanceOf(owner), 100e6);
        assertFalse(managerRegistry.isPool(vault), "the mark was handed back");
    }

    /// @dev The 23.1M pulled out of the Uniswap pair land here by plain transfer and leave the
    ///      same way as everything bought.
    function test_tokensSentInDirectlyLeaveWithTheRest() public {
        vm.prank(owner);
        token.mint(address(buyback), 23_100_000e18);

        _sell(1_000e18);

        vm.prank(owner);
        buyback.withdraw(address(token), makeAddr("vault"), 23_101_000e18);

        assertEq(token.balanceOf(address(buyback)), 0);
    }

    /// @dev Withdraw restores what it found rather than clearing the flag.
    function test_poolDestinationKeepsItsMark() public {
        _sell(1_000e18);

        address vault = makeAddr("vault");
        vm.startPrank(owner);
        managerRegistry.setPoolStatus(vault, true);
        buyback.withdraw(address(token), vault, 1_000e18);
        vm.stopPrank();

        assertTrue(managerRegistry.isPool(vault));
    }

    function test_tokenWithdrawalNeedsTheRegistrySlot() public {
        _sell(1_000e18);

        vm.startPrank(owner);
        managerRegistry.setLimitedSellerAddress(address(0));
        vm.expectRevert("ManagerRegistry: Not a reward system or limited seller");
        buyback.withdraw(address(token), makeAddr("vault"), 1_000e18);

        // USDC does not go through the token gate and is unaffected.
        buyback.withdraw(address(usdc), owner, 1e6);
        vm.stopPrank();
    }

    function test_onlyOwnerWithdraws() public {
        _sell(1_000e18);

        vm.prank(attacker);
        vm.expectRevert();
        buyback.withdraw(address(usdc), attacker, 1e6);
    }

    // ── Wiring ──

    /// @dev The token itself blocks it — the revert comes from there, not from Buyback.
    function test_sellingIsImpossibleUntilTheAddressIsMarkedAsPool() public {
        vm.prank(owner);
        managerRegistry.setPoolStatus(address(buyback), false);

        vm.startPrank(holder);
        token.approve(address(buyback), 1_000e18);
        vm.expectRevert("Token: Buying is disabled");
        buyback.sell(1_000e18);
        vm.stopPrank();
    }

    // ── Price ──

    function test_ownerChangesThePrice() public {
        vm.prank(owner);
        buyback.setPrice(3e4);

        _sell(1_000e18);
        assertEq(usdc.balanceOf(holder), 30e6, "1000 tokens at $0.03");
    }

    function test_priceIsNeverZero() public {
        vm.prank(owner);
        vm.expectRevert(Buyback.ZeroAmount.selector);
        buyback.setPrice(0);
    }

    function test_onlyOwnerSetsThePrice() public {
        vm.prank(attacker);
        vm.expectRevert();
        buyback.setPrice(1e4);
    }

    function test_priceNeedNotDivideEvenly() public {
        vm.prank(owner);
        buyback.setPrice(21_000); // $0.021

        _sell(1_000e18);
        assertEq(usdc.balanceOf(holder), 21e6);
        assertEq(token.balanceOf(holder), 0);
    }

    function test_onlyOwnerUpgrades() public {
        address newImpl = address(new Buyback());

        vm.prank(attacker);
        vm.expectRevert();
        buyback.upgradeToAndCall(newImpl, "");

        vm.prank(owner);
        buyback.upgradeToAndCall(newImpl, "");
    }

    function testFuzz_sellTakesEverythingAndPaysTheFlooredRate(uint256 amount) public {
        amount = bound(amount, UNIT, 500_000e18);

        vm.prank(owner);
        token.mint(holder, amount);
        vm.prank(owner);
        usdc.mint(address(buyback), 10_000_000e6);

        uint256 before = token.balanceOf(holder);
        _sell(amount);

        assertEq(before - token.balanceOf(holder), amount, "the whole amount was taken");
        assertEq(usdc.balanceOf(holder), amount * PRICE / 1e18);
    }
}
