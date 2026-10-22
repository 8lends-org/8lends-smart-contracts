// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { EasyStart } from "../../../contracts/bonus/EasyStart.sol";
import { USDC } from "../../../contracts/test-tokens/usdc.sol";
import { TestERC20 } from "../../../contracts/test-tokens/testerc20.sol";

/// @dev Stands in for ManagerRegistry: the predicates EasyStart reads.
contract RegistryStub {
    mapping(address => bool) public operators;
    mapping(address => bool) public admins;
    mapping(address => bool) public frozen;
    mapping(address => address) public recovery;

    function setOperator(address a, bool v) external { operators[a] = v; }
    function setAdmin(address a, bool v) external { admins[a] = v; }
    function setFrozen(address a, bool v) external { frozen[a] = v; }
    function setRecovery(address user, address to) external { recovery[user] = to; }

    mapping(address => address) public canonicalOf;
    function setCanonical(address superseded, address head) external { canonicalOf[superseded] = head; }
    function headOf(address u) external view returns (address) {
        address head = canonicalOf[u];
        return head == address(0) ? u : head;
    }

    function isOperator(address a) external view returns (bool) { return operators[a]; }
    function isAdmin(address a) external view returns (bool) { return admins[a]; }
    function isFrozen(address a) external view returns (bool) { return frozen[a]; }
    function recipientOf(address u) external view returns (address) {
        address to = recovery[u];
        return to == address(0) ? u : to;
    }
}

contract EasyStartTest is Test {
    EasyStart internal es;
    USDC internal usdc;
    RegistryStub internal registry;

    address internal owner = address(this);
    address internal operator = makeAddr("operator");
    address internal admin = makeAddr("admin");
    address internal outsider = makeAddr("outsider");

    uint256 internal participantKey = 0xA11CE;
    address internal participant;

    uint128 internal constant DEPOSIT = 97e6;
    uint64 internal constant TERM = 6 days;
    uint32 internal constant COUNT = 2;
    uint128 internal constant REWARD = 4e6;

    function setUp() public {
        participant = vm.addr(participantKey);

        usdc = USDC(address(new ERC1967Proxy(
            address(new USDC()),
            abi.encodeCall(TestERC20.initialize, (owner, "USD Coin", "USDC", 6))
        )));
        registry = new RegistryStub();
        registry.setOperator(operator, true);
        registry.setAdmin(admin, true);

        EasyStart impl = new EasyStart();
        bytes memory data = abi.encodeCall(
            EasyStart.initialize,
            (address(registry), address(usdc), DEPOSIT, TERM, COUNT, REWARD)
        );
        es = EasyStart(address(new ERC1967Proxy(address(impl), data)));

        usdc.mint(participant, DEPOSIT);
        usdc.mint(address(es), 1_000e6); // the gift pool
        vm.warp(1_700_000_000);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    function _auth(uint256 key, address from, uint256 value, bytes32 nonce, uint256 validBefore)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, address(es), value, uint256(0), validBefore, nonce
        ));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _enter() internal returns (bytes32 nonce) {
        nonce = keccak256("enter");
        bytes memory sig = _auth(participantKey, participant, DEPOSIT, nonce, block.timestamp + 1 hours);
        vm.prank(operator);
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);
    }

    // ── entry ───────────────────────────────────────────────────────────────────

    /// @dev The whole point of the 3009 path: the participant never sends a transaction, so an
    ///      address with no native balance has to be able to enter.
    function test_entryWorksFromAnAddressWithNoEth() public {
        assertEq(participant.balance, 0, "participant must hold no ETH");
        _enter();

        assertTrue(es.participated(participant));
        assertEq(usdc.balanceOf(participant), 0);
        (uint256 dueAt, uint256 amount) = es.payoutAt(participant, COUNT);
        assertEq(dueAt, block.timestamp + TERM, "last payout is the end of the term");
        assertEq(amount, REWARD / COUNT);
    }

    function test_entryIsRefusedToAnyoneButAnOperator() public {
        bytes32 nonce = keccak256("enter");
        bytes memory sig = _auth(participantKey, participant, DEPOSIT, nonce, block.timestamp + 1 hours);

        vm.prank(outsider);
        vm.expectRevert(EasyStart.NotOperator.selector);
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);

        // the participant cannot let himself in either
        vm.prank(participant);
        vm.expectRevert(EasyStart.NotOperator.selector);
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);
    }

    function test_secondEntryFromTheSameAddressIsRefused() public {
        _enter();
        usdc.mint(participant, DEPOSIT);

        bytes32 nonce = keccak256("enter-again");
        bytes memory sig = _auth(participantKey, participant, DEPOSIT, nonce, block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(EasyStart.AlreadyParticipated.selector);
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);
    }

    /// @dev The amount is written by the contract, not taken from the caller, so an authorization
    ///      for anything else simply does not verify.
    function test_anAuthorizationForAnotherAmountDoesNotVerify() public {
        bytes32 nonce = keccak256("wrong-amount");
        bytes memory sig = _auth(participantKey, participant, DEPOSIT - 1, nonce, block.timestamp + 1 hours);

        vm.prank(operator);
        vm.expectRevert();
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);
    }

    function test_theSameAuthorizationCannotBeSpentTwice() public {
        bytes32 nonce = _enter();
        assertTrue(usdc.authorizationState(participant, nonce), "nonce is consumed");

        address second = vm.addr(0xB0B);
        usdc.mint(second, DEPOSIT);
        bytes memory sig = _auth(0xB0B, second, DEPOSIT, nonce, block.timestamp + 1 hours);
        vm.prank(operator);
        es.deposit(second, 0, block.timestamp + 1 hours, nonce, sig);

        // ...but not twice for the same authorizer
        vm.prank(operator);
        vm.expectRevert();
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);
    }

    // ── schedule ────────────────────────────────────────────────────────────────

    /// @dev The last payout is what the deposit comes with — before the end of the term it must not
    ///      be reachable, whatever the rounding of the earlier ones.
    function test_theLastPayoutIsNotAvailableBeforeTheEndOfTheTerm() public {
        _enter();
        uint256 start = block.timestamp;

        vm.warp(start + TERM - 1);
        (uint256 reward, uint256 principal) = es.claimable(participant);
        assertEq(reward, REWARD / COUNT, "only the earlier payouts");
        assertEq(principal, 0, "the deposit is not due yet");

        vm.warp(start + TERM);
        (reward, principal) = es.claimable(participant);
        // nothing was collected on the way, so the whole gift is owed at once
        assertEq(reward, REWARD, "the last payout unlocks with the term");
        assertEq(principal, DEPOSIT);
    }

    /// @dev Separate methods, so neither can carry the other's money: the gift must not drag the
    ///      deposit out early, and the return must not smuggle the gift past its schedule.
    function test_theGiftAndTheDepositLeaveByTheirOwnMethods() public {
        _enter();
        vm.warp(block.timestamp + TERM);

        vm.prank(participant);
        es.claimReward(participant);
        assertEq(usdc.balanceOf(participant), REWARD, "the gift alone");

        vm.prank(participant);
        es.claimPrincipal(participant);
        assertEq(usdc.balanceOf(participant), REWARD + DEPOSIT, "and then the deposit");

        // neither method pays twice
        vm.prank(participant);
        vm.expectRevert(EasyStart.NothingToClaim.selector);
        es.claimReward(participant);
        vm.prank(participant);
        vm.expectRevert(EasyStart.NothingToClaim.selector);
        es.claimPrincipal(participant);
    }

    /// @dev Neither the term nor the gift divides by the count, which is where an advertised
    ///      moment and the real one part company and where the rounding of the sums shows. Both
    ///      halves of the advertisement have to hold, and the whole schedule has to add up: five
    ///      over three is 1, 2, 2.
    function test_payoutAtIsTheMomentAndTheSumItActuallyPays() public {
        vm.prank(admin);
        es.setParameters(DEPOSIT, 10, 3, 5);
        _enter();

        uint256 taken;
        for (uint256 i = 1; i <= 3; i++) {
            (uint256 dueAt, uint256 amount) = es.payoutAt(participant, i);

            vm.warp(dueAt - 1);
            (uint256 before,) = es.claimable(participant);
            assertEq(before, 0, "not yet, a second before");

            vm.warp(dueAt);
            (uint256 atDue,) = es.claimable(participant);
            assertEq(atDue, amount, "the sum is the one advertised");

            vm.prank(participant);
            es.claimReward(participant);
            taken += amount;
            assertEq(usdc.balanceOf(participant), taken);
        }
        assertEq(taken, 5, "the schedule sums to the whole gift");

        // and nothing grows after the last one
        vm.warp(block.timestamp + 10 days);
        vm.prank(participant);
        vm.expectRevert(EasyStart.NothingToClaim.selector);
        es.claimReward(participant);
    }

    /// @dev The deposit is not reachable through the gift's method before the term is over.
    function test_thePrincipalCannotBeTakenEarly() public {
        _enter();
        vm.warp(block.timestamp + TERM / COUNT);

        vm.prank(participant);
        vm.expectRevert(EasyStart.NothingToClaim.selector);
        es.claimPrincipal(participant);

        vm.prank(participant);
        es.claimReward(participant);
        assertEq(usdc.balanceOf(participant), REWARD / COUNT, "only the matured payout");
    }

    // ── who may claim ───────────────────────────────────────────────────────────

    function test_theOperatorClaimsAndTheMoneyGoesToTheParticipant() public {
        _enter();
        vm.warp(block.timestamp + TERM);

        vm.prank(operator);
        es.claimReward(participant);
        vm.prank(operator);
        es.claimPrincipal(participant);

        assertEq(usdc.balanceOf(participant), REWARD + DEPOSIT);
        assertEq(usdc.balanceOf(operator), 0, "the caller gets nothing");
    }

    function test_anOutsiderCannotClaim() public {
        _enter();
        vm.warp(block.timestamp + TERM);

        vm.prank(outsider);
        vm.expectRevert(EasyStart.NotAllowed.selector);
        es.claimReward(participant);
    }

    /// @dev The liveness property the whole shape is for: the participant's money does not depend on
    ///      the backend key still being an operator.
    function test_theParticipantClaimsWithTheOperatorKeyRevoked() public {
        _enter();
        vm.warp(block.timestamp + TERM);
        registry.setOperator(operator, false);

        vm.prank(participant);
        es.claimReward(participant);
        vm.prank(participant);
        es.claimPrincipal(participant);
        assertEq(usdc.balanceOf(participant), REWARD + DEPOSIT);
    }

    /// @dev Whoever asks: an address that never entered is not a participant first and foremost,
    ///      and the error says so instead of blaming the caller's rights.
    function test_claimOnSomeoneWhoNeverEntered() public {
        vm.prank(outsider);
        vm.expectRevert(EasyStart.NotAParticipant.selector);
        es.claimReward(outsider);

        vm.prank(outsider);
        vm.expectRevert(EasyStart.NotAParticipant.selector);
        es.claimReward(makeAddr("a stranger to both"));

        vm.expectRevert(EasyStart.NotAParticipant.selector);
        es.payoutAt(outsider, 1);
    }

    // ── recovery and freeze ─────────────────────────────────────────────────────

    /// @dev The new wallet takes over whole: it may press for itself, the operator may press for
    ///      it, either address names the same participation, and nothing lands on the stolen one.
    function test_theRecoveredWalletTakesOverTheParticipation() public {
        _enter();
        address recovered = vm.addr(0xB0B);
        registry.setRecovery(participant, recovered);
        registry.setCanonical(recovered, participant);
        vm.warp(block.timestamp + TERM);

        vm.prank(recovered);
        es.claimReward(recovered);

        vm.prank(operator);
        es.claimPrincipal(participant);

        assertEq(usdc.balanceOf(recovered), REWARD + DEPOSIT, "money goes to the new wallet");
        assertEq(usdc.balanceOf(participant), 0, "and not to the stolen one");
    }

    /// @dev The reason the record is filed under the head of the chain: a participant whose wallet
    ///      was replaced is the same person, and must not be able to take a second gift under the
    ///      new address.
    function test_aReplacedWalletCannotEnterASecondTime() public {
        _enter();

        address recovered = vm.addr(0xB0B);
        registry.setRecovery(participant, recovered);
        registry.setCanonical(recovered, participant);

        assertTrue(es.participated(recovered), "the new wallet is the same participation");

        usdc.mint(recovered, DEPOSIT);
        bytes32 nonce = keccak256("second-gift");
        bytes memory sig = _auth(0xB0B, recovered, DEPOSIT, nonce, block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(EasyStart.AlreadyParticipated.selector);
        es.deposit(recovered, 0, block.timestamp + 1 hours, nonce, sig);
    }

    /// @dev The replaced wallet is treated as stolen: it may not press the button even though the
    ///      money would go to the recovery address anyway.
    function test_theReplacedWalletCanDoNothing() public {
        _enter();
        address recovered = vm.addr(0xB0B);
        registry.setRecovery(participant, recovered);
        registry.setCanonical(recovered, participant);
        vm.warp(block.timestamp + TERM);

        vm.prank(participant);
        vm.expectRevert(EasyStart.NotAllowed.selector);
        es.claimReward(participant);

        vm.prank(participant);
        vm.expectRevert(EasyStart.NotAllowed.selector);
        es.claimReward(recovered);
    }

    /// @dev A freeze on the live wallet has to stop the money even though the record sits under the
    ///      address it replaced.
    function test_aFreezeOnTheLiveWalletStopsTheOldParticipation() public {
        _enter();
        address recovered = vm.addr(0xB0B);
        registry.setRecovery(participant, recovered);
        registry.setCanonical(recovered, participant);
        registry.setFrozen(recovered, true);
        vm.warp(block.timestamp + TERM);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EasyStart.AccountFrozen.selector, recovered));
        es.claimReward(participant);
    }

    function test_aFrozenParticipantGetsNothing() public {
        _enter();
        registry.setFrozen(participant, true);
        vm.warp(block.timestamp + TERM);

        vm.prank(participant);
        vm.expectRevert(abi.encodeWithSelector(EasyStart.AccountFrozen.selector, participant));
        es.claimReward(participant);

        // the operator is not a way around it — the flag is read on whose money moves
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EasyStart.AccountFrozen.selector, participant));
        es.claimReward(participant);
    }

    /// @dev Entry is not gated on it: the deposit only moves money into the contract, and it comes
    ///      back to recipientOf whoever that turns out to be. The gate is on the way out.
    function test_aFrozenAddressStillEnters() public {
        registry.setFrozen(participant, true);
        _enter();
        assertTrue(es.participated(participant));
    }

    /// @dev The term runs while the account is frozen; nothing is forfeited by being stopped.
    function test_afterUnfreezingEverythingAccruedIsStillThere() public {
        _enter();
        registry.setFrozen(participant, true);
        vm.warp(block.timestamp + TERM);
        registry.setFrozen(participant, false);

        vm.prank(participant);
        es.claimReward(participant);
        vm.prank(participant);
        es.claimPrincipal(participant);
        assertEq(usdc.balanceOf(participant), REWARD + DEPOSIT);
    }

    // ── parameters ──────────────────────────────────────────────────────────────

    function test_participantKeepsTheTermsHeEnteredOn() public {
        _enter();
        uint256 start = block.timestamp;

        vm.prank(admin);
        es.setParameters(400e6, 60 days, 10, 60e6);

        vm.warp(start + TERM);
        vm.prank(participant);
        es.claimReward(participant);
        vm.prank(participant);
        es.claimPrincipal(participant);
        assertEq(usdc.balanceOf(participant), REWARD + DEPOSIT, "the old schedule in full");
    }

    function test_parametersAreOwnerOrAdminOnly() public {
        vm.prank(outsider);
        vm.expectRevert(EasyStart.NotAuthorized.selector);
        es.setParameters(1e6, 1 days, 1, 1);

        vm.prank(operator);
        vm.expectRevert(EasyStart.NotAuthorized.selector);
        es.setParameters(1e6, 1 days, 1, 1);

        vm.prank(admin);
        es.setParameters(1e6, 1 days, 1, 1);
        assertEq(es.depositAmount(), 1e6);

        es.setParameters(2e6, 2 days, 2, 2); // owner
        assertEq(es.depositAmount(), 2e6);
    }

    function test_degenerateParametersAreRefused() public {
        vm.startPrank(admin);
        vm.expectRevert(EasyStart.InvalidParameters.selector);
        es.setParameters(0, TERM, COUNT, REWARD);
        vm.expectRevert(EasyStart.InvalidParameters.selector);
        es.setParameters(DEPOSIT, 0, COUNT, REWARD);
        vm.expectRevert(EasyStart.InvalidParameters.selector);
        es.setParameters(DEPOSIT, TERM, 0, REWARD);
        vm.expectRevert(EasyStart.InvalidParameters.selector);
        es.setParameters(DEPOSIT, TERM, COUNT, 0);
        vm.stopPrank();
    }

    function test_theBoundsHold() public {
        uint128 cap = es.MAX_DEPOSIT();

        vm.startPrank(admin);
        vm.expectRevert(EasyStart.AboveLimit.selector);
        es.setParameters(cap + 1, TERM, COUNT, 1e6);

        // One unit over the share allowed.
        vm.expectRevert(EasyStart.AboveLimit.selector);
        es.setParameters(100e6, TERM, COUNT, 15e6 + 1);

        es.setParameters(cap, TERM, COUNT, 75e6);
        vm.stopPrank();
        assertEq(es.depositAmount(), cap, "the cap itself is allowed");
        assertEq(es.rewardAmount(), 75e6, "and so is the share exactly");
    }

    function test_theBoundsHoldAtDeployment() public {
        EasyStart impl = new EasyStart();
        bytes memory beyond = abi.encodeCall(
            EasyStart.initialize,
            (address(registry), address(usdc), es.MAX_DEPOSIT() + 1, TERM, COUNT, 1e6)
        );

        vm.expectRevert(EasyStart.AboveLimit.selector);
        new ERC1967Proxy(address(impl), beyond);
    }

    // ── the entrance ────────────────────────────────────────────────────────────

    function test_aClosedEntranceRefusesEvenTheOperator() public {
        es.setKillSwitch(true);
        assertTrue(es.killSwitch());

        bytes32 nonce = keccak256("enter");
        bytes memory sig = _auth(participantKey, participant, DEPOSIT, nonce, block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(EasyStart.DepositsAreClosed.selector);
        es.deposit(participant, 0, block.timestamp + 1 hours, nonce, sig);
        assertFalse(es.participated(participant));

        es.setKillSwitch(false);
        _enter();
        assertTrue(es.participated(participant), "the same entry goes through once the door is open");
    }

    /// @dev The switch is for the entrance: a promise already made is still paid.
    function test_aClosedEntranceLeavesTheScheduleAlone() public {
        _enter();
        uint256 start = block.timestamp;

        es.setKillSwitch(true);

        vm.warp(start + TERM);
        vm.prank(participant);
        es.claimReward(participant);
        vm.prank(participant);
        es.claimPrincipal(participant);
        assertEq(usdc.balanceOf(participant), REWARD + DEPOSIT, "the whole cycle, door shut");
    }

    /// @dev Not the admin either, although he moves the campaign terms: the switch is the Safe's.
    /// @dev Shutting is the owner's alone; opening back is an admin's too, so a premature stop
    ///      does not wait for the Safe.
    function test_theAdminStopsItButOnlyTheOwnerRestarts() public {
        vm.prank(operator);
        vm.expectRevert(EasyStart.NotAuthorized.selector);
        es.setKillSwitch(true);

        vm.prank(outsider);
        vm.expectRevert(EasyStart.NotAuthorized.selector);
        es.setKillSwitch(true);
        assertFalse(es.killSwitch(), "neither the operator nor a stranger stops it");

        vm.prank(admin);
        es.setKillSwitch(true);
        assertTrue(es.killSwitch(), "the admin stops it alone, within the minute");

        vm.prank(admin);
        vm.expectRevert(EasyStart.NotAuthorized.selector);
        es.setKillSwitch(false);
        assertTrue(es.killSwitch(), "but cannot undo his own stop");

        vm.prank(operator);
        vm.expectRevert(EasyStart.NotAuthorized.selector);
        es.setKillSwitch(false);

        es.setKillSwitch(false);
        assertFalse(es.killSwitch(), "restarting takes the owner");
    }

    // ── money ───────────────────────────────────────────────────────────────────

    function test_onlyTheOwnerWithdrawsAndNothingBoundsTheAmount() public {
        vm.prank(admin);
        vm.expectRevert();
        es.withdraw(address(usdc), admin, 1);

        vm.prank(operator);
        vm.expectRevert();
        es.withdraw(address(usdc), operator, 1);

        uint256 all = usdc.balanceOf(address(es));
        es.withdraw(address(usdc), owner, all);
        assertEq(usdc.balanceOf(address(es)), 0, "the owner may take everything");
    }
}
