// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract ManagerRegistryTest is Setup {
    // ═══════════════════════════════════════════════════════════════
    //                     ROLE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    function test_setManagerStatus_onlyManagerOrOwner() public {
        vm.prank(attacker);
        vm.expectRevert("ManagerRegistry: Not a manager");
        managerRegistry.setManagerStatus(attacker, true);
    }

    function test_managerCanPromoteOtherManager() public {
        // An existing manager can add new managers — this is a design choice
        // but means a compromised manager can escalate
        address newManager = makeAddr("newManager");

        vm.prank(manager);
        managerRegistry.setManagerStatus(newManager, true);

        assertTrue(managerRegistry.managers(newManager));
    }

    function test_isManager_includesRewardSystem() public {
        // RewardSystem address counts as a manager (line 119 of ManagerRegistry.sol)
        assertTrue(managerRegistry.isManager(address(rewardSystem)));
    }

    function test_isRewardSystem_includesRewards2() public {
        // Both rewardSystem and rewards2 count as rewardSystem
        assertTrue(managerRegistry.isRewardSystem(address(rewardSystem)));
        assertTrue(managerRegistry.isRewardSystem(address(rewards2)));
    }

    function test_isRewardSystem_randomAddress_returnsFalse() public view {
        assertFalse(managerRegistry.isRewardSystem(attacker));
    }

    // ═══════════════════════════════════════════════════════════════
    //                   POOL STATUS
    // ═══════════════════════════════════════════════════════════════

    function test_setPoolStatus_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        managerRegistry.setPoolStatus(attacker, true);
    }

    function test_setPoolStatusForReward_onlyRewardSystem() public {
        vm.prank(attacker);
        vm.expectRevert("ManagerRegistry: Not a reward system or limited seller");
        managerRegistry.setPoolStatusForReward(attacker, true);
    }

    // ═══════════════════════════════════════════════════════════════
    //                 INVESTOR CLAIM ADDRESS
    // ═══════════════════════════════════════════════════════════════

    function test_claimAddress_defaultsToInvestor() public view {
        address result = managerRegistry.getInvestorClaimAddress(investor);
        assertEq(result, investor);
    }

    function test_claimAddress_returnsOverride_whenSet() public {
        address alt = makeAddr("altClaim");

        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(investor, alt);

        assertEq(managerRegistry.getInvestorClaimAddress(investor), alt);
    }

    function test_setClaimAddress_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        managerRegistry.setInvestorClaimAddress(investor, attacker);
    }

    // ═══════════════════════════════════════════════════════════════
    //                 CONTRACT ADDRESSES
    // ═══════════════════════════════════════════════════════════════

    function test_isFundraise_correctAddress() public view {
        assertTrue(managerRegistry.isFundraise(address(fundraise)));
        assertFalse(managerRegistry.isFundraise(attacker));
    }

    function test_isTreasury_correctAddress() public view {
        assertTrue(managerRegistry.isTreasury(address(treasury)));
        assertFalse(managerRegistry.isTreasury(attacker));
    }
}
