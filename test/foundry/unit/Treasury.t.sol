// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract TreasuryTest is Setup {
    function test_withdraw_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.withdraw(address(usdc), 100e6, attacker);
    }

    function test_withdraw_transfersTokens() public {
        // Fund treasury
        vm.prank(owner);
        usdc.mint(address(treasury), 1_000e6);

        vm.prank(owner);
        treasury.withdraw(address(usdc), 1_000e6, owner);

        assertEq(usdc.balanceOf(owner), 1_000e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_withdraw_canWithdrawERC20Tokens() public {
        // Fund treasury with project tokens
        vm.prank(owner);
        token.mint(address(treasury), 5_000e18);

        // Token transfers are restricted when buying is disabled.
        // Treasury can only send 8LNDS tokens to pools or reward systems.
        // Enable buying first, then withdraw.
        vm.prank(owner);
        token.enableBuying();

        vm.prank(owner);
        treasury.withdraw(address(token), 5_000e18, manager);

        assertEq(token.balanceOf(manager), 5_000e18);
    }

    function test_treasury_receivesPlatformFees() public {
        // Create, invest, and fund a project — treasury gets platform fee
        uint256 pid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, pid, 25_000e6, inviter);
        _fundProject(pid);

        // Platform fee = 3% of 25,000 = 750 USDC
        uint256 fee = (25_000e6 * PLATFORM_FEE) / BASIS_POINTS;
        assertEq(usdc.balanceOf(address(treasury)), fee, "Treasury should hold platform fee");
    }
}
