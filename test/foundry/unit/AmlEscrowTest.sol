// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../mocks/MockUSDC.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {IAmlEscrow} from "../../../contracts/escrow/interfaces/IAmlEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockEscrowFactory {
    address public usdc;
    address public fundraise;
    uint256 public minInvestAmount = 1e6;
    uint256 public maxInvestAmount = 500e6;
    uint256 public refundTimeout = 30 days;

    constructor(address _usdc, address _fundraise) {
        usdc = _usdc;
        fundraise = _fundraise;
    }

    function setLimits(uint256 _min, uint256 _max) external {
        minInvestAmount = _min;
        maxInvestAmount = _max;
    }

    function setRefundTimeout(uint256 _t) external {
        refundTimeout = _t;
    }

    // Convenience wrappers so the test can call through factory
    function callApprove(address escrow, uint256 reqId) external {
        IAmlEscrow(escrow).approveInvest(reqId);
    }

    function callReject(address escrow, uint256 reqId) external {
        IAmlEscrow(escrow).rejectInvest(reqId);
    }

    // IEscrowFactory.escrows stub (not used by AmlEscrow itself, but interface completeness)
    function escrows(address /*user*/) external pure returns (address) {
        return address(0);
    }

    // Callbacks from AmlEscrow for indexer-friendly events (no-op in mock)
    function onInvestRequested(address, uint256, uint256, uint256, address) external {}
    function onRequestCancelled(address, uint256, uint256, uint256, address) external {}
}

contract MockFundraise {
    using SafeERC20 for IERC20;

    bool public shouldRevert;
    string public revertMsg;
    address public lastInvestor;
    uint256 public lastPid;
    uint256 public lastAmount;

    address public usdcAddr;

    constructor(address _usdc) {
        usdcAddr = _usdc;
    }

    function setRevert(bool _r, string memory _reason) external {
        shouldRevert = _r;
        revertMsg = _reason;
    }

    function investFromEscrow(
        address investor,
        uint256 pid,
        uint256 amount,
        address /*inviter*/
    ) external {
        if (shouldRevert) {
            revert(revertMsg);
        }
        lastInvestor = investor;
        lastPid = pid;
        lastAmount = amount;
        // Pull USDC from the escrow (escrow has safeIncreaseAllowance'd us)
        IERC20(usdcAddr).safeTransferFrom(msg.sender, address(this), amount);
    }
}

// ---------------------------------------------------------------------------
// Reentrancy-attack token
// ---------------------------------------------------------------------------

/// @dev A malicious ERC20 that re-enters escrow.invest during transferFrom
contract MaliciousUSDC is MockUSDC {
    address public targetEscrow;
    uint256 public pid;
    uint256 public attackAmount;
    address public inviter;
    bool public attackArmed;

    function armAttack(
        address _escrow,
        uint256 _pid,
        uint256 _amount,
        address _inviter
    ) external {
        targetEscrow = _escrow;
        pid = _pid;
        attackAmount = _amount;
        inviter = _inviter;
        attackArmed = true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (attackArmed) {
            attackArmed = false; // prevent infinite loop
            // Re-enter the escrow's invest function
            IAmlEscrow(targetEscrow).invest(pid, attackAmount, inviter);
        }
        return super.transferFrom(from, to, amount);
    }
}

// ---------------------------------------------------------------------------
// AmlEscrowTest
// ---------------------------------------------------------------------------

contract AmlEscrowTest is Test {
    AmlEscrow public escrow;
    MockEscrowFactory public factory;
    MockFundraise public mockFundraise;
    MockUSDC public usdc;

    address public user = makeAddr("user");
    address public attacker = makeAddr("attacker");
    address public inviter = makeAddr("inviter");

    uint256 constant PID = 1;
    uint256 constant AMOUNT = 100e6; // 100 USDC

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        usdc = new MockUSDC();
        mockFundraise = new MockFundraise(address(usdc));
        factory = new MockEscrowFactory(address(usdc), address(mockFundraise));

        escrow = new AmlEscrow();
        escrow.initialize(user, address(factory));

        // Give user USDC and approve escrow
        usdc.mint(user, 10_000e6);
        vm.prank(user);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // =========================================================================
    // 1. Initialize
    // =========================================================================

    /// @dev test 1: calling initialize a second time reverts
    function test_Initialize_TwiceReverts() public {
        vm.expectRevert("Already initialized");
        escrow.initialize(user, address(factory));
    }

    /// @dev test 2: zero user address reverts
    function test_Initialize_ZeroUser_Reverts() public {
        AmlEscrow e = new AmlEscrow();
        vm.expectRevert("Zero address");
        e.initialize(address(0), address(factory));
    }

    /// @dev test 3: zero factory address reverts
    function test_Initialize_ZeroFactory_Reverts() public {
        AmlEscrow e = new AmlEscrow();
        vm.expectRevert("Zero address");
        e.initialize(user, address(0));
    }

    /// @dev test 4: state is set correctly after initialize
    function test_Initialize_SetsState() public {
        AmlEscrow e = new AmlEscrow();
        address someUser = makeAddr("someUser");
        address someFactory = makeAddr("someFactory");
        e.initialize(someUser, someFactory);

        assertEq(e.user(), someUser);
        assertEq(e.factory(), someFactory);
    }

    // =========================================================================
    // 2. invest()
    // =========================================================================

    /// @dev test 5: non-user cannot call invest
    function test_Invest_OnlyUser() public {
        vm.prank(attacker);
        vm.expectRevert("Not user");
        escrow.invest(PID, AMOUNT, inviter);
    }

    /// @dev test 6: amount below minimum reverts
    function test_Invest_BelowMinimum() public {
        uint256 below = factory.minInvestAmount() - 1;
        vm.prank(user);
        vm.expectRevert("Below minimum");
        escrow.invest(PID, below, inviter);
    }

    /// @dev test 7: amount above maximum reverts
    function test_Invest_AboveMaximum() public {
        uint256 above = factory.maxInvestAmount() + 1;
        // mint extra so balance is not the limiting factor
        usdc.mint(user, above);
        vm.prank(user);
        vm.expectRevert("Above maximum");
        escrow.invest(PID, above, inviter);
    }

    /// @dev test 8: happy path — USDC pulled, request stored, event emitted
    function test_Invest_PullsUsdcAndCreatesPending() public {
        uint256 userBalBefore = usdc.balanceOf(user);
        uint256 escrowBalBefore = usdc.balanceOf(address(escrow));

        vm.expectEmit(true, true, false, true);
        emit IAmlEscrow.InvestRequested(user, 0, PID, AMOUNT, inviter, block.timestamp, block.timestamp + factory.refundTimeout());

        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // USDC moved
        assertEq(usdc.balanceOf(user), userBalBefore - AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), escrowBalBefore + AMOUNT);

        // Request stored correctly
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(0);
        assertEq(req.pid, PID);
        assertEq(req.amount, AMOUNT);
        assertEq(req.inviter, inviter);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Pending));
        assertEq(escrow.getRequestCount(), 1);
    }

    /// @dev test 9: multiple concurrent invest requests are independent
    function test_Invest_MultipleConcurrentRequests() public {
        uint256 amt0 = 10e6;
        uint256 amt1 = 20e6;
        uint256 amt2 = 30e6;

        vm.startPrank(user);
        escrow.invest(PID, amt0, inviter);
        escrow.invest(PID + 1, amt1, address(0));
        escrow.invest(PID + 2, amt2, attacker);
        vm.stopPrank();

        assertEq(escrow.getRequestCount(), 3);

        IAmlEscrow.InvestRequest memory r0 = escrow.getRequest(0);
        IAmlEscrow.InvestRequest memory r1 = escrow.getRequest(1);
        IAmlEscrow.InvestRequest memory r2 = escrow.getRequest(2);

        assertEq(r0.amount, amt0);
        assertEq(r1.amount, amt1);
        assertEq(r2.amount, amt2);
        assertEq(uint8(r0.status), uint8(IAmlEscrow.RequestStatus.Pending));
        assertEq(uint8(r1.status), uint8(IAmlEscrow.RequestStatus.Pending));
        assertEq(uint8(r2.status), uint8(IAmlEscrow.RequestStatus.Pending));
    }

    // =========================================================================
    // 3. approveInvest()
    // =========================================================================

    /// @dev test 10: non-factory cannot call approveInvest
    function test_ApproveInvest_OnlyFactory() public {
        // Create a pending request first
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        vm.prank(attacker);
        vm.expectRevert("Not factory");
        escrow.approveInvest(0);
    }

    /// @dev test 11: approving an already-approved request reverts
    function test_ApproveInvest_StatusMustBePending() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // First approve succeeds
        factory.callApprove(address(escrow), 0);

        // Second approve on the same request reverts
        vm.expectRevert("Not pending");
        factory.callApprove(address(escrow), 0);
    }

    /// @dev test 12: approve calls Fundraise, sets Approved, emits event
    function test_ApproveInvest_CallsFundraise_AndSetsApproved() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        vm.expectEmit(true, true, false, true);
        emit IAmlEscrow.InvestApproved(user, 0, PID, AMOUNT, inviter);

        factory.callApprove(address(escrow), 0);

        // MockFundraise recorded the call
        assertEq(mockFundraise.lastInvestor(), user);
        assertEq(mockFundraise.lastAmount(), AMOUNT);
        assertEq(mockFundraise.lastPid(), PID);

        // Status is Approved
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(0);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Approved));
    }

    /// @dev test 13: if Fundraise reverts the whole tx reverts, status stays Pending
    function test_ApproveInvest_FundraiseRevertsKeepsPending() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        mockFundraise.setRevert(true, "Investment failed");

        vm.expectRevert("Investment failed");
        factory.callApprove(address(escrow), 0);

        // State rolled back — request still Pending
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(0);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Pending));
    }

    // =========================================================================
    // 4. rejectInvest()
    // =========================================================================

    /// @dev test 14: non-factory cannot call rejectInvest
    function test_RejectInvest_OnlyFactory() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        vm.prank(attacker);
        vm.expectRevert("Not factory");
        escrow.rejectInvest(0);
    }

    /// @dev test 15: rejecting a non-Pending request reverts
    function test_RejectInvest_StatusMustBePending() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // Reject once -> Rejected
        factory.callReject(address(escrow), 0);

        // Reject again -> not Pending any more
        vm.expectRevert("Not pending");
        factory.callReject(address(escrow), 0);
    }

    /// @dev test 16: reject returns USDC to user, sets Rejected, emits event
    function test_RejectInvest_ReturnsUsdcToUser() public {
        uint256 userBalBefore = usdc.balanceOf(user);

        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // User lost USDC
        assertEq(usdc.balanceOf(user), userBalBefore - AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit IAmlEscrow.InvestRejected(user, 0, PID, AMOUNT, inviter);

        factory.callReject(address(escrow), 0);

        // USDC returned
        assertEq(usdc.balanceOf(user), userBalBefore);

        // Status is Rejected
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(0);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Rejected));
    }

    // =========================================================================
    // 5. cancelRequest()
    // =========================================================================

    /// @dev test 17: non-user cannot cancel
    function test_CancelRequest_OnlyUser() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        vm.prank(attacker);
        vm.expectRevert("Not user");
        escrow.cancelRequest(0);
    }

    /// @dev test 18: cancelling before timeout reverts
    function test_CancelRequest_BeforeTimeout_Reverts() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // Do NOT warp — still inside timeout window
        vm.prank(user);
        vm.expectRevert("Too early");
        escrow.cancelRequest(0);
    }

    /// @dev test 19: cancel after timeout returns USDC, sets Cancelled, emits event
    function test_CancelRequest_AfterTimeout_Cancelled() public {
        uint256 userBalBefore = usdc.balanceOf(user);

        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // Warp past refundTimeout
        vm.warp(block.timestamp + factory.refundTimeout());

        vm.expectEmit(true, true, false, true);
        emit IAmlEscrow.RequestCancelled(user, 0, PID, AMOUNT, inviter);

        vm.prank(user);
        escrow.cancelRequest(0);

        // USDC returned
        assertEq(usdc.balanceOf(user), userBalBefore);

        // Status is Cancelled (NOT Rejected)
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(0);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Cancelled));
    }

    /// @dev test 20: Cancelled and Rejected are distinct enum values
    function test_CancelledDistinctFromRejected() public pure {
        assertTrue(
            uint8(IAmlEscrow.RequestStatus.Cancelled) !=
                uint8(IAmlEscrow.RequestStatus.Rejected)
        );
    }

    /// @dev test 21: cannot cancel a request that is no longer Pending
    function test_CancelRequest_StatusMustBePending() public {
        vm.prank(user);
        escrow.invest(PID, AMOUNT, inviter);

        // Approve it first
        factory.callApprove(address(escrow), 0);

        // Now warp past timeout and attempt cancel — should revert "Not pending"
        vm.warp(block.timestamp + factory.refundTimeout());

        vm.prank(user);
        vm.expectRevert("Not pending");
        escrow.cancelRequest(0);
    }

    // =========================================================================
    // 6. getRequests() batch getter
    // =========================================================================

    /// @dev test 22: paginated batch getter returns correct slices
    function test_GetRequests_BatchGetter() public {
        // Push 5 requests
        vm.startPrank(user);
        for (uint256 i = 0; i < 5; i++) {
            escrow.invest(i, (i + 1) * 10e6, address(0));
        }
        vm.stopPrank();

        // getRequests(0, 3) → 3 items
        IAmlEscrow.InvestRequest[] memory slice0 = escrow.getRequests(0, 3);
        assertEq(slice0.length, 3);
        assertEq(slice0[0].pid, 0);
        assertEq(slice0[2].pid, 2);

        // getRequests(3, 10) → 2 items (only indices 3,4 exist)
        IAmlEscrow.InvestRequest[] memory slice1 = escrow.getRequests(3, 10);
        assertEq(slice1.length, 2);
        assertEq(slice1[0].pid, 3);
        assertEq(slice1[1].pid, 4);

        // getRequests(10, 5) → empty (fromIndex beyond length)
        IAmlEscrow.InvestRequest[] memory slice2 = escrow.getRequests(10, 5);
        assertEq(slice2.length, 0);
    }

    // =========================================================================
    // 7. Reentrancy guard
    // =========================================================================

    /// @dev test 23: reentrant call via malicious ERC20 is blocked by nonReentrant
    function test_NonReentrancy_OnInvest() public {
        // Deploy malicious token and a fresh escrow pointing at it
        MaliciousUSDC malUSDC = new MaliciousUSDC();
        MockFundraise malFundraise = new MockFundraise(address(malUSDC));
        MockEscrowFactory malFactory = new MockEscrowFactory(
            address(malUSDC),
            address(malFundraise)
        );

        AmlEscrow malEscrow = new AmlEscrow();
        malEscrow.initialize(user, address(malFactory));

        // Fund user with malicious token and approve
        malUSDC.mint(user, 10_000e6);
        vm.prank(user);
        malUSDC.approve(address(malEscrow), type(uint256).max);

        // Arm the re-entrancy attack: during transferFrom, call invest again
        malUSDC.armAttack(address(malEscrow), PID, AMOUNT, inviter);

        // The outer invest call should revert due to nonReentrant
        vm.prank(user);
        vm.expectRevert();
        malEscrow.invest(PID, AMOUNT, inviter);
    }
}
