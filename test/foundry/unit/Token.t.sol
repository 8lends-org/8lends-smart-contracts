// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract TokenTest is Setup {
    // ═══════════════════════════════════════════════════════════════
    //                    canTransfer MODIFIER
    // ═══════════════════════════════════════════════════════════════

    function test_transfer_blockedWhenBuyingDisabled() public {
        // Mint tokens to investor (via owner, allowed)
        vm.prank(owner);
        token.mint(investor, 1000e18);

        // Transfer to random address should fail (buying disabled by default)
        vm.prank(investor);
        vm.expectRevert("Token: Buying is disabled");
        token.transfer(attacker, 100e18);
    }

    function test_transfer_allowedToPool_whenBuyingDisabled() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        managerRegistry.setPoolStatus(pool, true);

        vm.prank(owner);
        token.mint(investor, 1000e18);

        // Transfer to pool should work even with buying disabled
        vm.prank(investor);
        token.transfer(pool, 100e18);

        assertEq(token.balanceOf(pool), 100e18);
    }

    function test_transfer_allowedToRewardSystem_whenBuyingDisabled() public {
        vm.prank(owner);
        token.mint(investor, 1000e18);

        // Transfer to RewardSystem should work (it's registered as rewardSystem)
        vm.prank(investor);
        token.transfer(address(rewardSystem), 100e18);

        assertEq(token.balanceOf(address(rewardSystem)), 100e18);
    }

    function test_transfer_allowedToAnyone_whenBuyingEnabled() public {
        vm.prank(owner);
        token.enableBuying();

        vm.prank(owner);
        token.mint(investor, 1000e18);

        vm.prank(investor);
        token.transfer(attacker, 100e18);

        assertEq(token.balanceOf(attacker), 100e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    MINT / BURN
    // ═══════════════════════════════════════════════════════════════

    function test_mint_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.mint(attacker, 100e18);
    }

    function test_mintReward_onlyRewardSystem() public {
        vm.prank(attacker);
        vm.expectRevert("Token: Not a reward system");
        token.mintReward(attacker, 100e18);
    }

    function test_mintReward_fromRewardSystem() public {
        // RewardSystem can mint via mintReward
        vm.prank(address(rewardSystem));
        token.mintReward(investor, 100e18);

        assertEq(token.balanceOf(investor), 100e18);
    }

    function test_burn_reducesBalance() public {
        vm.prank(owner);
        token.mint(owner, 1000e18);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(owner);
        token.burn(500e18);

        assertEq(token.balanceOf(owner), 500e18);
        assertEq(token.totalSupply(), supplyBefore - 500e18);
    }

    function test_disableMintingForever() public {
        vm.prank(owner);
        token.disableMintingForever();

        vm.prank(owner);
        vm.expectRevert("Token: Minting is disabled");
        token.mint(owner, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //             enableBuyingForever / canDisableBuying
    // ═══════════════════════════════════════════════════════════════

    function test_enableBuyingForever_setsCanDisableBuyingFalse() public {
        vm.prank(owner);
        token.enableBuyingForever();

        assertEq(token.buyingEnabled(), true);
        assertEq(token.canDisableBuying(), false);
    }

    function test_disableBuying_afterEnableBuyingForever_stillWorks() public {
        // BUG: canDisableBuying flag is never actually checked in disableBuying()
        vm.prank(owner);
        token.enableBuyingForever();

        // This should arguably fail, but disableBuying() doesn't check canDisableBuying
        vm.prank(owner);
        token.disableBuying();

        assertEq(token.buyingEnabled(), false, "Owner can still disable buying after enableBuyingForever");
    }
}
