// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

/// @notice Who may press the freeze, what it stops, and how it ends. The cases that matter are the
///         ones where the flag has to be read on someone other than the caller.
contract AccountFreezeTest is Setup {
    address public support;
    address public user;

    function setUp() public override {
        super.setUp();

        support = makeAddr("support");
        user = makeAddr("user");

        vm.prank(owner);
        managerRegistry.setSupportStatus(support, true);

        usdc.mint(user, 100_000e6);
        vm.prank(user);
        usdc.approve(address(fundraise), type(uint256).max);
    }

    // ── Who may press it ──

    function test_supportAndOperatorFreeze_managerDoesNot() public {
        vm.prank(support);
        managerRegistry.freeze(user);
        assertTrue(managerRegistry.isFrozen(user));

        vm.prank(support);
        managerRegistry.unfreeze(user);

        vm.prank(operator);
        managerRegistry.freeze(user);
        assertTrue(managerRegistry.isFrozen(user));

        vm.prank(manager);
        vm.expectRevert("ManagerRegistry: Not authorized");
        managerRegistry.freeze(makeAddr("other"));
    }

    /// @dev The asymmetry is the point: a stolen backend key must not be able to clear the blocks
    ///      it set off.
    function test_onlySupportLiftsAFreeze() public {
        vm.prank(operator);
        managerRegistry.freeze(user);

        vm.prank(operator);
        vm.expectRevert("ManagerRegistry: Not support");
        managerRegistry.unfreeze(user);

        vm.prank(owner);
        vm.expectRevert("ManagerRegistry: Not support");
        managerRegistry.unfreeze(user);

        vm.prank(support);
        managerRegistry.unfreeze(user);
        assertFalse(managerRegistry.isFrozen(user));
    }

    function test_supportRoleIsGrantedByOwnerOrAdmin() public {
        address admin = makeAddr("admin");
        vm.prank(owner);
        managerRegistry.setAdminStatus(admin, true);

        vm.prank(manager);
        vm.expectRevert("ManagerRegistry: Not authorized");
        managerRegistry.setSupportStatus(makeAddr("s2"), true);

        vm.prank(admin);
        managerRegistry.setSupportStatus(makeAddr("s2"), true);
    }

    /// @dev A panic batch is not worth losing over one bad element.
    function test_freezeManySkipsZeroAndAlreadyFrozen() public {
        vm.prank(support);
        managerRegistry.freeze(user);

        address second = makeAddr("second");
        address[] memory who = new address[](3);
        who[0] = address(0);
        who[1] = user;
        who[2] = second;

        vm.prank(support);
        managerRegistry.freezeMany(who);

        assertTrue(managerRegistry.isFrozen(second));
        assertTrue(managerRegistry.isFrozen(user));
    }

    function test_freezeManyIsCapped() public {
        address[] memory who = new address[](201);
        vm.prank(support);
        vm.expectRevert("ManagerRegistry: Too many addresses");
        managerRegistry.freezeMany(who);
    }

    function test_freezeRejectsTheZeroAddress() public {
        vm.prank(support);
        vm.expectRevert("ManagerRegistry: Zero address");
        managerRegistry.freeze(address(0));
    }

    function test_unfreezeRefusesAnAccountThatIsNotFrozen() public {
        vm.prank(support);
        vm.expectRevert("ManagerRegistry: Not frozen");
        managerRegistry.unfreeze(user);
    }

    function test_freezeManyIsRefusedToAnOutsider() public {
        address[] memory who = new address[](1);
        who[0] = user;

        vm.prank(attacker);
        vm.expectRevert("ManagerRegistry: Not authorized");
        managerRegistry.freezeMany(who);
    }

    /// @dev Both events carry the caller: an incident review has to answer who pressed it, and a
    ///      freeze is the one action a single key performs alone.
    function test_bothEventsNameWhoPressed() public {
        vm.expectEmit(true, true, false, false, address(managerRegistry));
        emit ManagerRegistry.AccountFrozen(user, support);
        vm.prank(support);
        managerRegistry.freeze(user);

        vm.expectEmit(true, true, false, false, address(managerRegistry));
        emit ManagerRegistry.AccountUnfrozen(user, support);
        vm.prank(support);
        managerRegistry.unfreeze(user);
    }

    /// @dev The lift that happens inside setInvestorClaimAddress has to be visible too, or an
    ///      indexer following the events would still show the account as stopped.
    function test_theRecoveryLiftEmitsUnfrozenToo() public {
        vm.prank(support);
        managerRegistry.freeze(user);

        vm.expectEmit(true, true, false, false, address(managerRegistry));
        emit ManagerRegistry.AccountUnfrozen(user, owner);
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(user, makeAddr("recovery"));
    }

    // ── What it stops in Fundraise ──

    function test_frozenInvestorCannotInvest() public {
        uint256 pid = _createProject(1_000e6, 10_000e6);

        uint256 nonce = fundraise.userNonces(user) + 1;
        bytes memory sig = _signInvest(user, pid, 1_000e6, nonce, address(0));

        vm.prank(support);
        managerRegistry.freeze(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccountFrozen(address)", user));
        fundraise.investUpdateV2(pid, 1_000e6, nonce, sig, address(0));
    }

    function test_frozenInvestorCannotClaim() public {
        uint256 pid = _createProject(1_000e6, 10_000e6);
        _investAs(user, pid, 2_000e6, address(0));
        _fundProject(pid);
        _repayFull(pid);

        vm.prank(support);
        managerRegistry.freeze(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccountFrozen(address)", user));
        fundraise.claim(pid, user);

        vm.prank(support);
        managerRegistry.unfreeze(user);
        vm.prank(user);
        fundraise.claim(pid, user);
    }

    /// @dev The admin is the only caller allowed to claim for someone else, so he is the one who
    ///      proves the freeze outranks that right — and the case a check written on msg.sender
    ///      would let through.
    function test_anAdminCannotClaimForAFrozenInvestor() public {
        uint256 pid = _createProject(1_000e6, 10_000e6);
        _investAs(user, pid, 2_000e6, address(0));
        _fundProject(pid);
        _repayFull(pid);

        address admin = makeAddr("admin");
        vm.prank(owner);
        managerRegistry.setAdminStatus(admin, true);

        vm.prank(support);
        managerRegistry.freeze(user);

        // Allowed on a clean address — see Fundraise.t.sol — and refused on this one.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AccountFrozen(address)", user));
        fundraise.claim(pid, user);
    }

    /// @dev The gate sits ahead of the routing check, so a frozen account is turned away before
    ///      the contract looks at whether there is a mandate at all.
    function test_frozenInvestorCannotClaimThroughAMandate() public {
        uint256 pid = _createProject(1_000e6, 10_000e6);

        vm.prank(support);
        managerRegistry.freeze(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccountFrozen(address)", user));
        fundraise.claimForMandate(pid, user, bytes32(0));
    }

    function test_frozenInvestorCannotWithdrawBeforeFunding() public {
        uint256 pid = _createProject(5_000e6, 10_000e6);
        _investAs(user, pid, 1_000e6, address(0));

        vm.prank(support);
        managerRegistry.freeze(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccountFrozen(address)", user));
        fundraise.withdrawInvestment(pid, user);
    }

    // ── How it ends ──

    /// @dev Naming a recovery address supersedes the freeze: payouts already go elsewhere, and
    ///      holding the old address only blocks what the recovery redirects.
    function test_namingARecoveryAddressLiftsTheFreeze() public {
        vm.prank(support);
        managerRegistry.freeze(user);

        address recovery = makeAddr("recovery");
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(user, recovery);

        assertFalse(managerRegistry.isFrozen(user));
        assertTrue(managerRegistry.isCompromised(user));
    }

    function test_aFrozenAddressIsRefusedAsTheRecoveryTarget() public {
        address recovery = makeAddr("recovery");
        vm.prank(support);
        managerRegistry.freeze(recovery);

        vm.prank(owner);
        vm.expectRevert("Claim address is frozen");
        managerRegistry.setInvestorClaimAddress(user, recovery);
    }

    /// @dev If the new wallet is stolen too, the same button has to work on it.
    function test_theLiveEndOfARecoveryChainCanBeFrozen() public {
        address recovery = makeAddr("recovery");
        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(user, recovery);

        vm.prank(support);
        managerRegistry.freeze(recovery);
        assertTrue(managerRegistry.isFrozen(recovery));
    }
}
