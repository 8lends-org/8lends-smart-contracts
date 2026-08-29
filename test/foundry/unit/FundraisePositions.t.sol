// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {Market} from "../../../contracts/core/market/Market.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FundraisePositionsTest is Setup {
    uint256 pid;
    address marketCaller;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);

        // Register a market caller address for transferPosition tests
        marketCaller = makeAddr("marketCaller");
        vm.prank(owner);
        managerRegistry.setMarketAddress(marketCaller);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    POSITION STORAGE (Task 1.1)
    // ═══════════════════════════════════════════════════════════════

    function test_invest_createsSinglePosition() public {
        _investAs(investor, pid, 5_000e6, inviter);

        assertEq(fundraise.getPositionCount(investor, pid), 1);
        Fundraise.InvestorInfo[] memory positions = fundraise.getInvestorPositions(investor, pid);
        assertEq(positions.length, 1);
        assertEq(positions[0].investedAmount, 5_000e6);
        assertEq(positions[0].totalClaimed, 0);
    }

    function test_invest_twice_createsTwoPositions() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        assertEq(fundraise.getPositionCount(investor, pid), 2);
        Fundraise.InvestorInfo[] memory positions = fundraise.getInvestorPositions(investor, pid);
        assertEq(positions.length, 2);
        assertEq(positions[0].investedAmount, 5_000e6);
        assertEq(positions[1].investedAmount, 3_000e6);
    }

    function test_invest_aggregateStillCorrect() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 8_000e6, "aggregate must be sum of positions");
    }

    function test_getPositionCount_zeroForNonInvestor() public view {
        assertEq(fundraise.getPositionCount(attacker, pid), 0);
    }

    function test_getInvestorPositions_emptyForNonInvestor() public view {
        Fundraise.InvestorInfo[] memory positions = fundraise.getInvestorPositions(attacker, pid);
        assertEq(positions.length, 0);
    }

    function test_invest_differentInvestors_separatePositions() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor2, pid, 7_000e6, inviter);

        assertEq(fundraise.getPositionCount(investor, pid), 1);
        assertEq(fundraise.getPositionCount(investor2, pid), 1);

        Fundraise.InvestorInfo[] memory pos1 = fundraise.getInvestorPositions(investor, pid);
        Fundraise.InvestorInfo[] memory pos2 = fundraise.getInvestorPositions(investor2, pid);
        assertEq(pos1[0].investedAmount, 5_000e6);
        assertEq(pos2[0].investedAmount, 7_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    TRANSFER POSITION (Task 1.2)
    // ═══════════════════════════════════════════════════════════════

    function test_transferPosition_movesSpecificPosition() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        address recipient = makeAddr("recipient");

        // Transfer position at index 0 (5000)
        vm.prank(marketCaller);
        fundraise.transferPosition(pid, investor, recipient, 0, 1);

        // Investor: position 0 zeroed, position 1 still there
        Fundraise.InvestorInfo[] memory fromPos = fundraise.getInvestorPositions(investor, pid);
        assertEq(fromPos[0].investedAmount, 0, "position 0 should be zeroed");
        assertEq(fromPos[1].investedAmount, 3_000e6, "position 1 unchanged");

        // Recipient: has 1 position with 5000
        Fundraise.InvestorInfo[] memory toPos = fundraise.getInvestorPositions(recipient, pid);
        assertEq(toPos.length, 1);
        assertEq(toPos[0].investedAmount, 5_000e6);

        // Aggregate updated correctly
        (uint256 fromAgg,) = fundraise.investorInfo(investor, pid);
        (uint256 toAgg,) = fundraise.investorInfo(recipient, pid);
        assertEq(fromAgg, 3_000e6, "from aggregate should be 3000");
        assertEq(toAgg, 5_000e6, "to aggregate should be 5000");
    }

    function test_transferPosition_movesSecondPosition() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        address recipient = makeAddr("recipient");

        // Transfer position at index 1 (3000)
        vm.prank(marketCaller);
        fundraise.transferPosition(pid, investor, recipient, 1, 2);

        Fundraise.InvestorInfo[] memory fromPos = fundraise.getInvestorPositions(investor, pid);
        assertEq(fromPos[0].investedAmount, 5_000e6, "position 0 unchanged");
        assertEq(fromPos[1].investedAmount, 0, "position 1 should be zeroed");

        Fundraise.InvestorInfo[] memory toPos = fundraise.getInvestorPositions(recipient, pid);
        assertEq(toPos.length, 1);
        assertEq(toPos[0].investedAmount, 3_000e6);
    }

    function test_transferPosition_revert_invalidIndex() public {
        _investAs(investor, pid, 5_000e6, inviter);

        vm.prank(marketCaller);
        vm.expectRevert(Fundraise.PositionIndexOutOfBounds.selector);
        fundraise.transferPosition(pid, investor, makeAddr("r"), 5, 1);
    }

    function test_transferPosition_revert_zeroAmountPosition() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        address recipient = makeAddr("recipient");

        // Transfer position 0 first
        vm.prank(marketCaller);
        fundraise.transferPosition(pid, investor, recipient, 0, 1);

        // Try to transfer same position again — already zeroed
        vm.prank(marketCaller);
        vm.expectRevert(Fundraise.PositionHasZeroAmount.selector);
        fundraise.transferPosition(pid, investor, recipient, 0, 2);
    }

    function test_transferPosition_revert_notMarket() public {
        _investAs(investor, pid, 5_000e6, inviter);

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAMarket.selector);
        fundraise.transferPosition(pid, investor, makeAddr("r"), 0, 1);
    }

    function test_transferPosition_emitsEvent() public {
        _investAs(investor, pid, 5_000e6, inviter);
        address recipient = makeAddr("recipient");

        vm.prank(marketCaller);
        vm.expectEmit(true, true, true, true);
        emit Fundraise.InvestmentTransferred(pid, investor, recipient, 5_000e6, 42);
        fundraise.transferPosition(pid, investor, recipient, 0, 42);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    WITHDRAW + POSITIONS (Task 1.3)
    // ═══════════════════════════════════════════════════════════════

    function test_withdrawInvestment_clearsPositions() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        // Cancel the project
        vm.prank(manager);
        fundraise.cancelProject(pid);

        // Withdraw
        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);

        // Aggregate zeroed
        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 0, "aggregate should be zero");

        // All positions zeroed
        Fundraise.InvestorInfo[] memory positions = fundraise.getInvestorPositions(investor, pid);
        assertEq(positions.length, 2, "positions array length preserved");
        assertEq(positions[0].investedAmount, 0, "position 0 zeroed");
        assertEq(positions[1].investedAmount, 0, "position 1 zeroed");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    BACKFILL (Task 2.2)
    // ═══════════════════════════════════════════════════════════════

    function test_backfillPositions_success() public {
        // Simulate old-style aggregate-only investor by directly setting investorInfo
        // We invest normally (which creates positions), then test backfill on a different investor
        // For a clean test: invest as investor, then backfill for investor2 who has aggregate but no positions

        // Invest as investor2 via normal flow (creates positions)
        _investAs(investor2, pid, 10_000e6, inviter);
        _investAs(investor2, pid, 5_000e6, inviter);

        // Verify positions were created via invest
        assertEq(fundraise.getPositionCount(investor2, pid), 2);

        // For backfill test, we need an investor with aggregate but NO positions
        // We can't simulate this easily in foundry since _invest always creates positions now
        // Instead, test the backfill on a fresh project where we manually set aggregate via transferInvestment

        // Create a new project and invest as investor
        uint256 pid2 = _createProject(50_000e6, 100_000e6);
        _investAs(investor, pid2, 20_000e6, inviter);

        // Transfer the entire aggregate to investor2 via old transferInvestment (no position created for investor2)
        vm.prank(marketCaller);
        fundraise.transferInvestment(pid2, investor, investor2, false, 999);

        // investor2 now has aggregate but the positions came from transferInvestment which doesn't create positions in new array
        // Actually transferInvestment still updates aggregate but doesn't touch _investorPositions for to
        // Wait — _investAs created positions for investor on pid2, and transferInvestment moved aggregate but not positions
        // So investor2 has aggregate of 20_000e6 on pid2 but 0 positions

        // Actually let me check: transferInvestment moves entire aggregate. It doesn't touch _investorPositions.
        // So investor2 gets aggregate = 20k, but _investorPositions[investor2][pid2] is empty.
        assertEq(fundraise.getPositionCount(investor2, pid2), 0, "no positions from old transfer");
        (uint256 aggAmount,) = fundraise.investorInfo(investor2, pid2);
        assertEq(aggAmount, 20_000e6, "aggregate present from transfer");

        // Now backfill
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 20_000e6;
        vm.prank(manager);
        fundraise.backfillPositions(investor2, pid2, amounts);

        assertEq(fundraise.getPositionCount(investor2, pid2), 1);
        Fundraise.InvestorInfo[] memory positions = fundraise.getInvestorPositions(investor2, pid2);
        assertEq(positions[0].investedAmount, 20_000e6);
    }

    function test_backfillPositions_revert_sumMismatch() public {
        uint256 pid2 = _createProject(50_000e6, 100_000e6);
        _investAs(investor, pid2, 20_000e6, inviter);

        vm.prank(marketCaller);
        fundraise.transferInvestment(pid2, investor, investor2, false, 999);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 15_000e6; // wrong amount
        vm.prank(manager);
        vm.expectRevert(Fundraise.SumMismatchWithAggregate.selector);
        fundraise.backfillPositions(investor2, pid2, amounts);
    }

    function test_backfillPositions_revert_alreadyExists() public {
        _investAs(investor, pid, 5_000e6, inviter);

        // investor already has positions from invest
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5_000e6;
        vm.prank(manager);
        vm.expectRevert(Fundraise.PositionsAlreadyExist.selector);
        fundraise.backfillPositions(investor, pid, amounts);
    }

    function test_backfillPositions_revert_notManager() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;
        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.backfillPositions(investor, pid, amounts);
    }

    function test_backfillPositions_revert_investorHasClaimed() public {
        // Invest enough to hit softCap → fund → partial repay → claim → transfer aggregate
        _investAs(investor, pid, 20_000e6, inviter);
        _fundProject(pid);
        _repay(pid, 5_000e6);

        vm.prank(investor);
        fundraise.claim(pid, investor);

        // investor now has totalClaimed > 0. Transfer aggregate to investor2 (no positions for investor2)
        vm.prank(marketCaller);
        fundraise.transferInvestment(pid, investor, investor2, false, 999);

        // investor2 has aggregate with totalClaimed > 0 but no positions
        assertEq(fundraise.getPositionCount(investor2, pid), 0);
        (, uint256 claimed) = fundraise.investorInfo(investor2, pid);
        assertGt(claimed, 0, "investor2 should have claimed > 0");

        // Backfill should revert
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 20_000e6;
        vm.prank(manager);
        vm.expectRevert(Fundraise.InvestorHasClaimed.selector);
        fundraise.backfillPositions(investor2, pid, amounts);
    }
}
