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
    //                    POSITION STORAGE
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
    //                    TRANSFER POSITION
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
    //                    WITHDRAW + POSITIONS
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
}
