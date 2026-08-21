// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {LeagueBonus} from "../../../contracts/league-bonus/LeagueBonus.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LeagueBonusTest is Setup {
    LeagueBonus public league;

    // Silver/Gold/Diamond mirror the screen prototype placeholders; Bronze is configurable too.
    uint256 constant BRONZE = 10e6;
    uint256 constant SILVER = 30e6;
    uint256 constant GOLD = 100e6;
    uint256 constant DIAMOND = 300e6;

    uint256 constant FUNDING = 10_000e6;

    address user1;
    address user2;
    address notOperator;

    /// @dev initialize takes a dynamic array whose length must equal the number of real leagues.
    function _amounts() internal pure returns (uint256[] memory a) {
        a = new uint256[](4);
        a[0] = BRONZE;
        a[1] = SILVER;
        a[2] = GOLD;
        a[3] = DIAMOND;
    }

    function setUp() public override {
        super.setUp();

        LeagueBonus impl = new LeagueBonus();
        bytes memory data = abi.encodeCall(
            LeagueBonus.initialize,
            (address(managerRegistry), address(usdc), _amounts())
        );
        league = LeagueBonus(address(new ERC1967Proxy(address(impl), data)));

        usdc.mint(address(league), FUNDING);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        notOperator = makeAddr("notOperator");
    }

    // ── initialize ──

    function test_initialize_setsAmountsPerLeague() public view {
        assertEq(league.bonusAmount(LeagueBonus.League.Bronze), BRONZE);
        assertEq(league.bonusAmount(LeagueBonus.League.Silver), SILVER);
        assertEq(league.bonusAmount(LeagueBonus.League.Gold), GOLD);
        assertEq(league.bonusAmount(LeagueBonus.League.Diamond), DIAMOND);
        assertEq(address(league.usdc()), address(usdc));
        assertEq(address(league.managerRegistry()), address(managerRegistry));
    }

    function test_initialize_revert_zeroManager() public {
        LeagueBonus impl = new LeagueBonus();
        bytes memory data = abi.encodeCall(
            LeagueBonus.initialize,
            (address(0), address(usdc), _amounts())
        );
        vm.expectRevert("Invalid managerRegistry");
        new ERC1967Proxy(address(impl), data);
    }

    function test_initialize_revert_amountsTooShort() public {
        LeagueBonus impl = new LeagueBonus();
        uint256[] memory short = new uint256[](3);
        bytes memory data = abi.encodeCall(
            LeagueBonus.initialize,
            (address(managerRegistry), address(usdc), short)
        );
        vm.expectRevert("Bad amounts length");
        new ERC1967Proxy(address(impl), data);
    }

    /// @dev The dangerous direction: without the length check the extra entry is silently dropped.
    function test_initialize_revert_amountsTooLong() public {
        LeagueBonus impl = new LeagueBonus();
        uint256[] memory long = new uint256[](5);
        long[0] = BRONZE;
        long[1] = SILVER;
        long[2] = GOLD;
        long[3] = DIAMOND;
        long[4] = 999e6;
        bytes memory data = abi.encodeCall(
            LeagueBonus.initialize,
            (address(managerRegistry), address(usdc), long)
        );
        vm.expectRevert("Bad amounts length");
        new ERC1967Proxy(address(impl), data);
    }

    /// @dev Pins the enum ordinals. Fails if a league is inserted rather than appended — an
    ///      insertion keeps the storage layout intact but silently reinterprets every stored
    ///      `highestBonusedLeague` and every `bonusAmount` key one league lower.
    function test_leagueOrdinalsArePinned() public pure {
        assertEq(uint8(LeagueBonus.League.None), 0);
        assertEq(uint8(LeagueBonus.League.Bronze), 1);
        assertEq(uint8(LeagueBonus.League.Silver), 2);
        assertEq(uint8(LeagueBonus.League.Gold), 3);
        assertEq(uint8(LeagueBonus.League.Diamond), 4);
    }

    function test_initialize_revert_zeroUsdc() public {
        LeagueBonus impl = new LeagueBonus();
        bytes memory data = abi.encodeCall(
            LeagueBonus.initialize,
            (address(managerRegistry), address(0), _amounts())
        );
        vm.expectRevert("Invalid usdc");
        new ERC1967Proxy(address(impl), data);
    }

    // ── acceptance: one bonus per promotion event, sized at its destination league ──

    function test_firstPromotion_paysDestinationLeagueAmount() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Silver);

        assertEq(usdc.balanceOf(user1), SILVER);
        assertTrue(league.hasAnyBonus(user1));
        assertEq(league.totalPaid(), SILVER);
        assertEq(league.totalBonusCount(), 1);

        assertEq(uint8(league.highestBonusedLeague(user1)), uint8(LeagueBonus.League.Silver));
    }

    /// Two separate promotion events (Bronze → Silver → Gold) pay two bonuses.
    function test_stepByStepPromotions_payPerEvent() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Silver);
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold);

        assertEq(usdc.balanceOf(user1), SILVER + GOLD);
        assertEq(league.totalPaid(), SILVER + GOLD);
        assertEq(league.totalBonusCount(), 2);

        // and a third event keeps paying
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Diamond);
        assertEq(usdc.balanceOf(user1), SILVER + GOLD + DIAMOND);
        assertEq(league.totalBonusCount(), 3);
    }

    /// Capital jumped several leagues in one event → one bonus at the destination league only.
    /// The skipped intermediate leagues are never paid, not even later.
    function test_multiLeagueJump_paysOnceAtDestinationAndBurnsSkippedLeagues() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Diamond);

        assertEq(usdc.balanceOf(user1), DIAMOND);
        assertEq(league.totalBonusCount(), 1);

        // Gold was skipped past — it can never be claimed afterwards
        assertFalse(league.qualifiesForBonus(user1, LeagueBonus.League.Gold));
        vm.prank(operator);
        vm.expectRevert("Invalid league or amount");
        league.sendBonus(user1, LeagueBonus.League.Gold);
    }

    /// Demotion then re-promotion into an already-paid league pays nothing.
    function test_demotionThenRePromotionToSameLeague_revert() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold);

        // the demotion happens off-chain only — nothing lowers the on-chain marker
        vm.prank(operator);
        vm.expectRevert("Invalid league or amount");
        league.sendBonus(user1, LeagueBonus.League.Gold);

        assertEq(usdc.balanceOf(user1), GOLD);
        assertEq(league.totalBonusCount(), 1);
    }

    /// The same recalculation running twice must not create a second payout. The replay reverts
    /// rather than being skipped, so the backend has to filter before submitting.
    function test_idempotency_repeatedBatchCallRevertsAndPaysOnce() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](1);
        leagues[0] = LeagueBonus.League.Gold;

        vm.prank(operator);
        league.sendBonusBatch(users, leagues);

        vm.prank(operator);
        vm.expectRevert("Invalid league or amount");
        league.sendBonusBatch(users, leagues);

        assertEq(usdc.balanceOf(user1), GOLD);
        assertEq(league.totalBonusCount(), 1);
        assertEq(league.totalPaid(), GOLD);
    }

    /// Bronze is a payable league like any other, and being paid for it does not block a later
    /// promotion into a higher one.
    function test_bronze_isPayableAndDoesNotBlockHigherLeagues() public {
        assertTrue(league.qualifiesForBonus(user1, LeagueBonus.League.Bronze));

        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Bronze);

        assertEq(usdc.balanceOf(user1), BRONZE);
        assertTrue(league.hasAnyBonus(user1));
        assertEq(uint8(league.highestBonusedLeague(user1)), uint8(LeagueBonus.League.Bronze));

        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Silver);
        assertEq(usdc.balanceOf(user1), BRONZE + SILVER);
        assertEq(league.totalBonusCount(), 2);
    }

    /// `None` is the reserved zero member, not a league — it can never be paid, and the attempt
    /// must not raise the marker.
    function test_none_revert_andDoesNotRaiseTheMarker() public {
        assertFalse(league.qualifiesForBonus(user1, LeagueBonus.League.None));

        vm.prank(operator);
        vm.expectRevert("Invalid league");
        league.sendBonus(user1, LeagueBonus.League.None);

        assertFalse(league.hasAnyBonus(user1), "marker not raised");

        // a real promotion still pays
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Bronze);
        assertEq(usdc.balanceOf(user1), BRONZE);
    }

    /// A league whose amount is still pending business input reverts loudly instead of marking the
    /// wallet, so the payout can be retried once the amount is configured.
    function test_zeroAmountLeague_revert_andDoesNotRaiseTheMarker() public {
        league.setBonusAmount(LeagueBonus.League.Silver, 0);

        vm.prank(operator);
        vm.expectRevert("Invalid league or amount");
        league.sendBonus(user1, LeagueBonus.League.Silver);

        assertFalse(league.hasAnyBonus(user1), "marker not raised");

        league.setBonusAmount(LeagueBonus.League.Silver, SILVER);
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Silver);
        assertEq(usdc.balanceOf(user1), SILVER);
    }

    // ── sendBonus: guards ──

    function test_sendBonus_revert_notOperator() public {
        vm.prank(notOperator);
        vm.expectRevert("Not an operator");
        league.sendBonus(user1, LeagueBonus.League.Silver);
    }

    /// The operator role exists precisely so that a hot backend key is not also a manager.
    /// A manager must therefore be rejected here even though it is a privileged address
    /// elsewhere in the protocol — if this test ever passes, the two sets have been blurred.
    function test_sendBonus_revert_managerIsNotOperator() public {
        assertTrue(managerRegistry.isManager(manager));
        assertFalse(managerRegistry.isOperator(manager));

        vm.prank(manager);
        vm.expectRevert("Not an operator");
        league.sendBonus(user1, LeagueBonus.League.Silver);
    }

    /// `isOperator` does not implicitly admit the owner, unlike the `|| msg.sender == owner()`
    /// pattern used by the setters in ManagerRegistry. Pinned deliberately: the Safe has to be
    /// added as an operator explicitly, and that grant is visible as an event.
    function test_sendBonus_revert_ownerIsNotOperator() public {
        assertFalse(managerRegistry.isOperator(owner));

        vm.prank(owner);
        vm.expectRevert("Not an operator");
        league.sendBonus(user1, LeagueBonus.League.Silver);
    }

    // ── sendBonusBatch ──

    function test_sendBonusBatch_mixedLeagues() public {
        address user3 = makeAddr("user3");

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](3);
        leagues[0] = LeagueBonus.League.Silver;
        leagues[1] = LeagueBonus.League.Gold;
        leagues[2] = LeagueBonus.League.Diamond;

        vm.prank(operator);
        league.sendBonusBatch(users, leagues);

        assertEq(usdc.balanceOf(user1), SILVER);
        assertEq(usdc.balanceOf(user2), GOLD);
        assertEq(usdc.balanceOf(user3), DIAMOND);
        assertEq(league.totalPaid(), SILVER + GOLD + DIAMOND);
        assertEq(league.totalBonusCount(), 3);
    }

    /// One entry targeting a league not above the wallet's last bonused one takes the whole batch
    /// down — no partial payouts.
    function test_sendBonusBatch_revert_notHigherLeague_isAtomic() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold); // pre-pay user1 up to Gold

        address[] memory users = new address[](2);
        users[0] = user2;
        users[1] = user1; // Silver ≤ Gold already paid → kills the batch
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](2);
        leagues[0] = LeagueBonus.League.Gold;
        leagues[1] = LeagueBonus.League.Silver;

        vm.prank(operator);
        vm.expectRevert("Invalid league or amount");
        league.sendBonusBatch(users, leagues);

        assertEq(usdc.balanceOf(user2), 0, "batch rolled back");
        assertEq(league.totalBonusCount(), 1); // only the pre-pay
    }

    /// A duplicated entry for the same league is a replay within one batch — it reverts too.
    function test_sendBonusBatch_revert_duplicateSameLeague() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user1;
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](2);
        leagues[0] = LeagueBonus.League.Silver;
        leagues[1] = LeagueBonus.League.Silver;

        vm.prank(operator);
        vm.expectRevert("Invalid league or amount");
        league.sendBonusBatch(users, leagues);

        assertEq(usdc.balanceOf(user1), 0);
        assertEq(league.totalBonusCount(), 0);
    }

    /// Two promotion events for one wallet batched together are both paid, in ascending order.
    function test_sendBonusBatch_sameUserTwoAscendingLeaguesBothPaid() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user1;
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](2);
        leagues[0] = LeagueBonus.League.Silver;
        leagues[1] = LeagueBonus.League.Gold;

        vm.prank(operator);
        league.sendBonusBatch(users, leagues);

        assertEq(usdc.balanceOf(user1), SILVER + GOLD);
        assertEq(league.totalBonusCount(), 2);
    }

    function test_sendBonusBatch_revert_lengthMismatch() public {
        address[] memory users = new address[](2);
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](1);

        vm.prank(operator);
        vm.expectRevert("Length mismatch");
        league.sendBonusBatch(users, leagues);
    }

    function test_sendBonusBatch_revert_empty() public {
        address[] memory users = new address[](0);
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](0);

        vm.prank(operator);
        vm.expectRevert("Empty array");
        league.sendBonusBatch(users, leagues);
    }

    function test_sendBonusBatch_revert_tooMany() public {
        address[] memory users = new address[](201);
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](201);

        vm.prank(operator);
        vm.expectRevert("Too many users");
        league.sendBonusBatch(users, leagues);
    }

    function test_sendBonusBatch_revert_notOperator() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](1);
        leagues[0] = LeagueBonus.League.Silver;

        vm.prank(notOperator);
        vm.expectRevert("Not an operator");
        league.sendBonusBatch(users, leagues);
    }

    /// Underfunding reverts the whole batch rather than silently paying a prefix.
    function test_sendBonusBatch_revert_insufficientBalance() public {
        league.withdraw(address(usdc), usdc.balanceOf(address(league)) - SILVER, owner);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        LeagueBonus.League[] memory leagues = new LeagueBonus.League[](2);
        leagues[0] = LeagueBonus.League.Silver;
        leagues[1] = LeagueBonus.League.Diamond;

        vm.prank(operator);
        vm.expectRevert("Insufficient USDC balance");
        league.sendBonusBatch(users, leagues);

        assertEq(usdc.balanceOf(user1), 0, "batch rolled back");
        assertEq(league.totalBonusCount(), 0);
    }

    // ── admin: changeable amounts ──

    function test_setBonusAmount_success() public {
        league.setBonusAmount(LeagueBonus.League.Gold, 150e6);
        assertEq(league.getBonusAmount(LeagueBonus.League.Gold), 150e6);

        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold);
        assertEq(usdc.balanceOf(user1), 150e6);
    }

    function test_setBonusAmount_revert_notOwner() public {
        vm.prank(notOperator);
        vm.expectRevert();
        league.setBonusAmount(LeagueBonus.League.Gold, 150e6);
    }

    /// `None` is not a league, so an amount for it would be dead config.
    function test_setBonusAmount_revert_none() public {
        vm.expectRevert("Invalid league");
        league.setBonusAmount(LeagueBonus.League.None, 10e6);
    }

    /// Each call touches exactly one league and leaves the others alone.
    function test_setBonusAmount_touchesOnlyTheGivenLeague() public {
        league.setBonusAmount(LeagueBonus.League.Gold, 120e6);

        assertEq(league.getBonusAmount(LeagueBonus.League.Gold), 120e6);
        assertEq(league.getBonusAmount(LeagueBonus.League.Bronze), BRONZE);
        assertEq(league.getBonusAmount(LeagueBonus.League.Silver), SILVER);
        assertEq(league.getBonusAmount(LeagueBonus.League.Diamond), DIAMOND);
        assertEq(league.getBonusAmount(LeagueBonus.League.None), 0);
    }

    function test_setBonusAmount_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(league));
        emit LeagueBonus.BonusAmountSet(LeagueBonus.League.Gold, 120e6);
        league.setBonusAmount(LeagueBonus.League.Gold, 120e6);
    }


    function test_setKillSwitch_success() public {
        league.setKillSwitch(true);
        assertTrue(league.killSwitch());

        league.setKillSwitch(false);
        assertFalse(league.killSwitch());
    }

    function test_updateContracts_emitsEffectiveAddresses() public {
        address newUsdc = makeAddr("newUsdc");

        // managerRegistry omitted (zero) → event must carry the unchanged current address
        vm.expectEmit(false, false, false, true, address(league));
        emit LeagueBonus.ContractsUpdated(address(managerRegistry), newUsdc);
        league.updateContracts(address(0), newUsdc);

        assertEq(address(league.managerRegistry()), address(managerRegistry));
        assertEq(address(league.usdc()), newUsdc);
    }

    function test_withdraw_success() public {
        address recipient = makeAddr("recipient");
        uint256 bal = usdc.balanceOf(address(league));
        league.withdraw(address(usdc), bal, recipient);
        assertEq(usdc.balanceOf(recipient), bal);
        assertEq(usdc.balanceOf(address(league)), 0);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(notOperator);
        vm.expectRevert();
        league.withdraw(address(usdc), 1e6, notOperator);
    }

    function test_withdraw_revert_zeroRecipient() public {
        vm.expectRevert("Invalid recipient");
        league.withdraw(address(usdc), 1e6, address(0));
    }

    // ── views ──

    function test_getStats() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold);

        (uint256 paid, uint256 count, uint256 balance) = league.getStats();
        assertEq(paid, GOLD);
        assertEq(count, 1);
        assertEq(balance, FUNDING - GOLD);
    }

    function test_getLeagueStats() public {
        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold);
        vm.prank(operator);
        league.sendBonus(user2, LeagueBonus.League.Gold);

        (uint256 paid, uint256 count) = league.getLeagueStats(LeagueBonus.League.Gold);
        assertEq(paid, GOLD * 2);
        assertEq(count, 2);

        (uint256 silverPaid, uint256 silverCount) = league.getLeagueStats(LeagueBonus.League.Silver);
        assertEq(silverPaid, 0);
        assertEq(silverCount, 0);
    }

    /// `None` is the zero value, so an unpaid wallet reads as None — distinct from every real
    /// league, Bronze included.
    function test_highestBonusedLeague_unpaidWalletIsNone() public view {
        assertEq(uint8(league.highestBonusedLeague(user1)), uint8(LeagueBonus.League.None));
        assertFalse(league.hasAnyBonus(user1));
    }

    function test_qualifiesForBonus_onlyStrictlyHigherLeagues() public {
        assertTrue(league.qualifiesForBonus(user1, LeagueBonus.League.Silver));

        vm.prank(operator);
        league.sendBonus(user1, LeagueBonus.League.Gold);

        assertFalse(league.qualifiesForBonus(user1, LeagueBonus.League.Silver), "lower league");
        assertFalse(league.qualifiesForBonus(user1, LeagueBonus.League.Gold), "same league");
        assertTrue(league.qualifiesForBonus(user1, LeagueBonus.League.Diamond), "higher league");
    }
}
