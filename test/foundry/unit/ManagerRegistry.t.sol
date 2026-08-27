// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract ManagerRegistryTest is Setup {
    // ═══════════════════════════════════════════════════════════════
    //                     ROLE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    function test_setManagerStatus_ownerOrManager() public {
        // Random address cannot set manager status.
        vm.prank(attacker);
        vm.expectRevert();
        managerRegistry.setManagerStatus(attacker, true);

        // Existing manager can set manager status.
        vm.prank(manager);
        managerRegistry.setManagerStatus(attacker, true);
        assertTrue(managerRegistry.managers(attacker));
    }

    function test_managerCanPromoteOtherManager() public {
        address newManager = makeAddr("newManager");

        vm.prank(manager);
        managerRegistry.setManagerStatus(newManager, true);
        assertTrue(managerRegistry.managers(newManager));
    }

    function test_isManager_includesRewardSystem() public view {
        // RewardSystem address counts as a manager (line 119 of ManagerRegistry.sol)
        assertTrue(managerRegistry.isManager(address(rewardSystem)));
    }

    function test_isRewardSystem_includesRewards2() public view {
        // Both rewardSystem and rewards2 count as rewardSystem
        assertTrue(managerRegistry.isRewardSystem(address(rewardSystem)));
        assertTrue(managerRegistry.isRewardSystem(address(rewards2)));
    }

    function test_isRewardSystem_randomAddress_returnsFalse() public view {
        assertFalse(managerRegistry.isRewardSystem(attacker));
    }

    // ═══════════════════════════════════════════════════════════════
    //                     OPERATOR ROLE
    // ═══════════════════════════════════════════════════════════════
    //
    // The operator role exists so that a hot backend key can do routine work (bonus
    // payouts) without also holding manager rights. Two properties carry that, and both
    // are the opposite of how `managers` behaves — hence the tests.

    /// Managers are self-expanding (see test_managerCanPromoteOtherManager). Operators are
    /// deliberately not: only the owner grants them. If this ever fails because someone
    /// "made it consistent with the rest of the file", the role is back to drifting.
    function test_setOperatorStatus_onlyOwner_notManager() public {
        address newOperator = makeAddr("newOperator");

        vm.prank(manager);
        vm.expectRevert();
        managerRegistry.setOperatorStatus(newOperator, true);

        vm.prank(attacker);
        vm.expectRevert();
        managerRegistry.setOperatorStatus(newOperator, true);

        vm.prank(owner);
        managerRegistry.setOperatorStatus(newOperator, true);
        assertTrue(managerRegistry.isOperator(newOperator));
    }

    /// Grant and revoke, state and event in both directions. Rotation of a backend key is
    /// exactly these two calls — no upgrade, no downtime.
    function test_setOperatorStatus_grantAndRevoke() public {
        address newOperator = makeAddr("newOperator");

        vm.expectEmit(true, true, true, true, address(managerRegistry));
        emit ManagerRegistry.OperatorUpdated(newOperator, true);
        vm.prank(owner);
        managerRegistry.setOperatorStatus(newOperator, true);
        assertTrue(managerRegistry.isOperator(newOperator));

        vm.expectEmit(true, true, true, true, address(managerRegistry));
        emit ManagerRegistry.OperatorUpdated(newOperator, false);
        vm.prank(owner);
        managerRegistry.setOperatorStatus(newOperator, false);
        assertFalse(managerRegistry.isOperator(newOperator));
    }

    /// `isOperator` reads the mapping only. Unlike `isManager`, which also admits
    /// `rewardSystemAddress`, no contract is implicitly an operator — and unlike the
    /// setters in this contract, the owner is not implicitly one either.
    function test_isOperator_noImplicitMembers() public view {
        // a manager is not an operator — pins that the migration actually removed isManager
        // from the operator predicate rather than OR-ing the two together
        assertTrue(managerRegistry.isManager(manager));
        assertFalse(managerRegistry.isOperator(manager));

        assertFalse(managerRegistry.isOperator(owner));
        assertFalse(managerRegistry.isOperator(address(rewardSystem)));
        assertFalse(managerRegistry.isOperator(address(rewards2)));
        assertFalse(managerRegistry.isOperator(address(fundraise)));
        assertFalse(managerRegistry.isOperator(attacker));
        assertFalse(managerRegistry.isOperator(address(0)));
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
