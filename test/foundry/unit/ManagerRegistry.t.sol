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

    function test_setClaimAddress_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        managerRegistry.setInvestorClaimAddress(investor, attacker);
    }

    // ═══════════════════════════════════════════════════════════════
    //                 RECOVERY CHAINS
    // ═══════════════════════════════════════════════════════════════

    /// Three successive incidents on one user: A stolen -> B, B stolen -> C, C stolen -> D. Support
    /// reports each one by whichever address it knows, so the calls come in as (A,B), (B,C), (C,D).
    function _chain() internal returns (address b, address c, address d) {
        b = makeAddr("walletB");
        c = makeAddr("walletC");
        d = makeAddr("walletD");

        vm.startPrank(owner);
        managerRegistry.setInvestorClaimAddress(investor, b);
        managerRegistry.setInvestorClaimAddress(b, c);
        managerRegistry.setInvestorClaimAddress(c, d);
        vm.stopPrank();
    }

    function test_recipientOf_resolvesFromAnyAddressOfTheChain() public {
        (address b, address c, address d) = _chain();

        assertEq(managerRegistry.recipientOf(investor), d);
        assertEq(managerRegistry.recipientOf(b), d);
        assertEq(managerRegistry.recipientOf(c), d);
        assertEq(managerRegistry.recipientOf(d), d);
        // No chain at all: the caller needs no fallback of its own.
        assertEq(managerRegistry.recipientOf(attacker), attacker);
    }

    /// The forward mapping stays keyed by the first address, so the chain never needs a walk.
    function test_chain_staysFlat() public {
        (address b, address c, address d) = _chain();

        assertEq(managerRegistry.canonicalOf(b), investor);
        assertEq(managerRegistry.canonicalOf(c), investor);
        assertEq(managerRegistry.canonicalOf(d), investor);
        assertEq(managerRegistry.canonicalOf(investor), address(0));
    }

    function test_isCompromised_trueForSupersededOnly() public {
        (address b, address c, address d) = _chain();

        assertTrue(managerRegistry.isCompromised(investor));
        assertTrue(managerRegistry.isCompromised(b));
        assertTrue(managerRegistry.isCompromised(c));
        // The live address is NOT compromised — flagging it would lock the user out of the market.
        assertFalse(managerRegistry.isCompromised(d));
        assertFalse(managerRegistry.isCompromised(attacker));
    }

    /// getInvestorClaimAddress has deployed call sites; the chain must not change what they read.
    function test_getInvestorClaimAddress_unchangedByChain() public {
        (address b, address c, address d) = _chain();

        assertEq(managerRegistry.getInvestorClaimAddress(investor), d);
        assertEq(managerRegistry.getInvestorClaimAddress(d), d);
        assertEq(managerRegistry.getInvestorClaimAddress(attacker), attacker);
        // b and c never became keys, so they fall back to themselves — exactly as before the chain
        // existed. That is why the new resolver is a separate function.
        assertEq(managerRegistry.getInvestorClaimAddress(b), b);
        assertEq(managerRegistry.getInvestorClaimAddress(c), c);
    }

    function test_setClaimAddress_rejectsAddressAlreadyInAChain() public {
        (address b,, address d) = _chain();

        vm.startPrank(owner);
        // Superseded address of this chain.
        vm.expectRevert("Claim address already in a chain");
        managerRegistry.setInvestorClaimAddress(d, b);

        // Head of another user's chain.
        address other = makeAddr("otherUser");
        address otherNew = makeAddr("otherUserNew");
        managerRegistry.setInvestorClaimAddress(other, otherNew);
        vm.expectRevert("Claim address already in a chain");
        managerRegistry.setInvestorClaimAddress(d, other);
        vm.stopPrank();
    }

    function test_setClaimAddress_rejectsSelf() public {
        (address b,,) = _chain();

        vm.startPrank(owner);
        vm.expectRevert("Claim address is the investor");
        managerRegistry.setInvestorClaimAddress(investor, investor);

        // Same guard, reached through the chain: b resolves to investor.
        vm.expectRevert("Claim address is the investor");
        managerRegistry.setInvestorClaimAddress(b, investor);
        vm.stopPrank();
    }

    function test_setClaimAddress_emitsCanonicalNotTheAddressPassedIn() public {
        address b = makeAddr("walletB");
        address c = makeAddr("walletC");

        vm.startPrank(owner);
        managerRegistry.setInvestorClaimAddress(investor, b);

        // Reported as (b, c), but indexers must see the canonical key.
        vm.expectEmit(true, true, false, false, address(managerRegistry));
        emit ManagerRegistry.InvestorClaimAddressSet(investor, c);
        managerRegistry.setInvestorClaimAddress(b, c);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                 MANDATE FACTORY
    // ═══════════════════════════════════════════════════════════════

    function test_mandateFactory_unsetUntilWritten() public {
        assertEq(managerRegistry.mandateFactory(), address(0));

        vm.prank(owner);
        vm.expectRevert("Invalid mandateFactory");
        managerRegistry.setMandateFactory(address(0));

        address factory = makeAddr("mandateFactory");
        vm.prank(owner);
        managerRegistry.setMandateFactory(factory);
        assertEq(managerRegistry.mandateFactory(), factory);
    }

    function test_setMandateFactory_onlyOwner() public {
        address factory = makeAddr("mandateFactory");

        vm.prank(attacker);
        vm.expectRevert();
        managerRegistry.setMandateFactory(factory);

        // Not even a manager.
        vm.prank(manager);
        vm.expectRevert();
        managerRegistry.setMandateFactory(factory);
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
