// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";

import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/interfaces/protocol/IAmlEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice MockUSDC for deploying a second token (non-USDC loan token)
/// Re-use the same MockUSDC ABI (already imported via Setup → MockUSDC.sol)
import "../mocks/MockUSDC.sol";

contract AmlEscrowIntegrationTest is Setup {
    // ── Escrow contracts ──
    AmlEscrow public escrowImpl;
    EscrowFactory public escrowFactory;

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();

        // Deploy AmlEscrow implementation
        escrowImpl = new AmlEscrow();

        // Deploy EscrowFactory as UUPS proxy (owner must be msg.sender inside initialize)
        EscrowFactory factoryImpl = new EscrowFactory();
        bytes memory initData = abi.encodeCall(
            EscrowFactory.initialize,
            (address(escrowImpl), address(fundraise), address(usdc), backend)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        escrowFactory = EscrowFactory(address(proxy));

        // Wire factory as Fundraise.amlGateway
        vm.prank(owner);
        fundraise.setAmlGateway(address(escrowFactory));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Create an escrow for a user (called by the user themselves)
    function _createEscrow(address _user) internal returns (AmlEscrow esc) {
        vm.prank(_user);
        esc = AmlEscrow(escrowFactory.createEscrow(_user));
    }

    /// @notice Mint USDC, approve escrow, call invest() — returns new requestId
    function _escrowInvest(
        AmlEscrow esc,
        address _user,
        uint256 _pid,
        uint256 _amount,
        address _inviter
    ) internal returns (uint256 requestId) {
        vm.prank(owner);
        usdc.mint(_user, _amount);

        vm.prank(_user);
        usdc.approve(address(esc), _amount);

        requestId = esc.getRequestCount(); // index of the request about to be pushed

        vm.prank(_user);
        esc.invest(_pid, _amount, _inviter);
    }

    /// @notice Build a ComingSoon project (startAt in the future)
    function _createProjectComingSoon(uint256 softCap, uint256 hardCap, uint256 startAtOffset)
        internal
        returns (uint256 projectId)
    {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: hardCap,
            softCap: softCap,
            totalInvested: 0,
            startAt: block.timestamp + startAtOffset,
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + startAtOffset + 7 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: PLATFORM_FEE,
                totalRepaid: 0,
                borrower: borrower,
                fundedTime: 0,
                loanToken: IERC20(address(usdc)),
                stage: Fundraise.Stage.ComingSoon
            })
        });
        vm.prank(manager);
        projectId = fundraise.createProject(proj, 1);
    }

    /// @notice Build a project with a custom loanToken
    function _createProjectWithToken(uint256 softCap, uint256 hardCap, address loanToken)
        internal
        returns (uint256 projectId)
    {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: hardCap,
            softCap: softCap,
            totalInvested: 0,
            startAt: block.timestamp - 10,
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + 7 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: PLATFORM_FEE,
                totalRepaid: 0,
                borrower: borrower,
                fundedTime: 0,
                loanToken: IERC20(loanToken),
                stage: Fundraise.Stage.ComingSoon
            })
        });
        vm.prank(manager);
        projectId = fundraise.createProject(proj, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 — Happy path: invest → approve → recorded on Fundraise
    // ─────────────────────────────────────────────────────────────────────────

    function test_HappyPath_InvestApprove() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);

        uint256 requestId = _escrowInvest(escrow, investor, pid, 300e6, inviter);

        // Expect the Invest event from Fundraise (not Approval from USDC) — pin emitter.
        vm.expectEmit(true, true, false, true, address(fundraise));
        emit Fundraise.Invest(pid, investor, 300e6);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, requestId);

        // Fundraise recorded investment against investor
        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 300e6, "investedAmount mismatch");

        // Escrow holds no USDC
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow should be empty");

        // Request status is Approved
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Approved), "status should be Approved");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 — Reject path: USDC returned to user
    // ─────────────────────────────────────────────────────────────────────────

    function test_RejectPath_ReturnsUsdcToUser() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 requestId = _escrowInvest(escrow, investor, pid, 200e6, inviter);

        // Escrow holds the USDC; user balance is 0
        assertEq(usdc.balanceOf(investor), 0, "investor should have 0 before reject");

        vm.prank(backend);
        escrowFactory.rejectInvest(investor, requestId);

        assertEq(usdc.balanceOf(investor), 200e6, "USDC not returned to investor");

        IAmlEscrow.InvestRequest memory req = escrow.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Rejected), "status should be Rejected");

        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow should be empty");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3 — Cancel after timeout
    // ─────────────────────────────────────────────────────────────────────────

    function test_CancelAfterTimeout() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 requestId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Immediate cancel should revert
        vm.prank(investor);
        vm.expectRevert(bytes("Too early"));
        escrow.cancelRequest(requestId);

        // Advance past timeout (30 days)
        vm.warp(block.timestamp + 30 days);

        vm.prank(investor);
        escrow.cancelRequest(requestId);

        assertEq(usdc.balanceOf(investor), 100e6, "USDC not restored after cancel");

        IAmlEscrow.InvestRequest memory req = escrow.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Cancelled), "status should be Cancelled");
        assertTrue(
            uint8(IAmlEscrow.RequestStatus.Cancelled) != uint8(IAmlEscrow.RequestStatus.Rejected),
            "Cancelled and Rejected must be distinct"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4 — Multiple requests on same escrow
    // ─────────────────────────────────────────────────────────────────────────

    function test_MultipleRequestsSameEscrow() public {
        uint256 pidA = _createProject(100e6, 1000e6);
        uint256 pidB = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);

        uint256 request0 = _escrowInvest(escrow, investor, pidA, 200e6, inviter);
        uint256 request1 = _escrowInvest(escrow, investor, pidB, 200e6, inviter);

        assertEq(request0, 0, "first request should be index 0");
        assertEq(request1, 1, "second request should be index 1");

        // Approve request 0 → project A invested
        vm.prank(backend);
        escrowFactory.approveInvest(investor, request0);

        (uint256 investedA,) = fundraise.investorInfo(investor, pidA);
        assertEq(investedA, 200e6, "investor should be recorded in project A");

        // Reject request 1 → 200e6 returned to user
        vm.prank(backend);
        escrowFactory.rejectInvest(investor, request1);

        assertEq(usdc.balanceOf(investor), 200e6, "USDC from rejected request not returned");

        IAmlEscrow.InvestRequest memory req0 = escrow.getRequest(request0);
        IAmlEscrow.InvestRequest memory req1 = escrow.getRequest(request1);
        assertEq(uint8(req0.status), uint8(IAmlEscrow.RequestStatus.Approved));
        assertEq(uint8(req1.status), uint8(IAmlEscrow.RequestStatus.Rejected));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5 — Reject then re-invest same project
    // ─────────────────────────────────────────────────────────────────────────

    function test_RejectThenReInvestSameProject() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);

        // First attempt — rejected
        uint256 request0 = _escrowInvest(escrow, investor, pid, 300e6, inviter);
        vm.prank(backend);
        escrowFactory.rejectInvest(investor, request0);

        assertEq(usdc.balanceOf(investor), 300e6, "USDC should be returned after reject");

        // Second attempt — approved
        // _escrowInvest mints & approves fresh USDC
        // But investor already has 300e6 from rejection; avoid double-minting:
        // Manually approve + invest using existing balance
        vm.prank(investor);
        usdc.approve(address(escrow), 300e6);
        uint256 request1 = escrow.getRequestCount();
        vm.prank(investor);
        escrow.invest(pid, 300e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, request1);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 300e6, "only one successful investment should be recorded");

        (,, uint256 totalInvested,,,,,) = fundraise.projects(pid);
        assertEq(totalInvested, 300e6, "project totalInvested should be 300e6");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6 — Approve on ComingSoon project → request stays Pending
    // ─────────────────────────────────────────────────────────────────────────

    function test_ApproveOnComingSoonProject_RequestStaysPending() public {
        // Project not yet open (startAt = now + 1 day)
        uint256 pid = _createProjectComingSoon(100e6, 1000e6, 1 days);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 requestId = _escrowInvest(escrow, investor, pid, 200e6, inviter);

        // approveInvest should revert because _invest returns false for ComingSoon
        vm.prank(backend);
        vm.expectRevert(Fundraise.InvestmentFailed.selector);
        escrowFactory.approveInvest(investor, requestId);

        // Request still Pending
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Pending), "request should remain Pending");

        // Backend can now reject → USDC returned
        vm.prank(backend);
        escrowFactory.rejectInvest(investor, requestId);

        assertEq(usdc.balanceOf(investor), 200e6, "USDC should be returned after reject");

        IAmlEscrow.InvestRequest memory reqAfter = escrow.getRequest(requestId);
        assertEq(uint8(reqAfter.status), uint8(IAmlEscrow.RequestStatus.Rejected));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 7 — Hardcap race: second approve reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_HardcapRace_SecondApproveReverts() public {
        uint256 pid = _createProject(100e6, 500e6);
        AmlEscrow escrow1 = _createEscrow(investor);
        AmlEscrow escrow2 = _createEscrow(investor2);

        uint256 req1 = _escrowInvest(escrow1, investor, pid, 400e6, inviter);
        uint256 req2 = _escrowInvest(escrow2, investor2, pid, 400e6, inviter);

        // Approve investor1 — succeeds
        vm.prank(backend);
        escrowFactory.approveInvest(investor, req1);

        (uint256 invested1,) = fundraise.investorInfo(investor, pid);
        assertEq(invested1, 400e6, "investor1 should have invested 400e6");

        // Approve investor2 — should revert (400+400 > 500 hardcap)
        vm.prank(backend);
        vm.expectRevert(Fundraise.InvestmentExceedsHardCap.selector);
        escrowFactory.approveInvest(investor2, req2);

        // investor2 request still Pending
        IAmlEscrow.InvestRequest memory req = escrow2.getRequest(req2);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Pending));

        // Backend rejects investor2 → USDC returned
        vm.prank(backend);
        escrowFactory.rejectInvest(investor2, req2);

        assertEq(usdc.balanceOf(investor2), 400e6, "investor2 USDC should be refunded");

        (uint256 invested2,) = fundraise.investorInfo(investor2, pid);
        assertEq(invested2, 0, "investor2 should have 0 invested");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 8 — Non-USDC loanToken: approve reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_NonUsdcLoanToken_ApproveReverts() public {
        // Deploy a second token that is NOT usdc
        MockUSDC otherToken = new MockUSDC();

        uint256 pid = _createProjectWithToken(100e6, 1000e6, address(otherToken));
        AmlEscrow escrow = _createEscrow(investor);
        uint256 requestId = _escrowInvest(escrow, investor, pid, 200e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.LoanTokenNotUsdc.selector);
        escrowFactory.approveInvest(investor, requestId);

        // Request still Pending
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IAmlEscrow.RequestStatus.Pending));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 9 — Below minimum amount enforced
    // ─────────────────────────────────────────────────────────────────────────

    function test_MinAmountEnforced() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);

        vm.prank(owner);
        usdc.mint(investor, 0.5e6);

        vm.prank(investor);
        usdc.approve(address(escrow), 0.5e6);

        vm.prank(investor);
        vm.expectRevert(bytes("Below minimum"));
        escrow.invest(pid, 0.5e6, inviter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 10 — Above maximum amount enforced
    // ─────────────────────────────────────────────────────────────────────────

    function test_MaxAmountEnforced() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);

        vm.prank(owner);
        usdc.mint(investor, 600e6);

        vm.prank(investor);
        usdc.approve(address(escrow), 600e6);

        vm.prank(investor);
        vm.expectRevert(bytes("Above maximum"));
        escrow.invest(pid, 600e6, inviter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 11 — RewardSystem records investor (not escrow) as participant
    // ─────────────────────────────────────────────────────────────────────────

    function test_RewardSystemIntegration_InvestorRecorded() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);

        // Record all logs so we can inspect the recordInvestment call
        vm.recordLogs();
        uint256 requestId = _escrowInvest(escrow, investor, pid, 300e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, requestId);

        // Primary assertion: Fundraise recorded correct invested amount for investor
        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 300e6, "investedAmount should be 300e6 for investor");

        // Check no investment was recorded against escrow address
        (uint256 escrowInvested,) = fundraise.investorInfo(address(escrow), pid);
        assertEq(escrowInvested, 0, "escrow address should have 0 invested amount");

        // Inspect emitted logs — verify Invest event was for investor, not escrow
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundInvestEvent = false;
        bytes32 investTopic = keccak256("Invest(uint256,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == investTopic) {
                // topics[1] = indexed projectId, data = (address investor, uint256 amount)
                // Decode non-indexed fields from data
                (address loggedInvestor, ) = abi.decode(logs[i].data, (address, uint256));
                assertEq(loggedInvestor, investor, "Invest event should record investor, not escrow");
                foundInvestEvent = true;
            }
        }
        assertTrue(foundInvestEvent, "Invest event not found in logs");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 12 — Direct investUpdateV2 still works (no regression)
    // ─────────────────────────────────────────────────────────────────────────

    function test_DirectInvestUpdateV2_NoRegression() public {
        uint256 pid = _createProject(100e6, 1000e6);

        _investAs(investor, pid, 250e6, inviter);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 250e6, "investedAmount should be 250e6");
        assertEq(fundraise.userNonces(investor), 1, "userNonce should be 1 after one invest");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 13 — Failed approve leaves request retryable
    // ─────────────────────────────────────────────────────────────────────────

    function test_FailedApproveLeavesRequestRetryable() public {
        // Project ComingSoon — not yet open
        uint256 pid = _createProjectComingSoon(100e6, 1000e6, 1 days);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 requestId = _escrowInvest(escrow, investor, pid, 200e6, inviter);

        // First approve fails (ComingSoon, before startAt)
        vm.prank(backend);
        vm.expectRevert(Fundraise.InvestmentFailed.selector);
        escrowFactory.approveInvest(investor, requestId);

        // Request must still be Pending
        IAmlEscrow.InvestRequest memory reqBefore = escrow.getRequest(requestId);
        assertEq(uint8(reqBefore.status), uint8(IAmlEscrow.RequestStatus.Pending), "should remain Pending after failed approve");

        // Warp past startAt — project will auto-transition to Open on next invest call
        vm.warp(block.timestamp + 2 days);

        // Retry approve — now succeeds
        vm.prank(backend);
        escrowFactory.approveInvest(investor, requestId);

        IAmlEscrow.InvestRequest memory reqAfter = escrow.getRequest(requestId);
        assertEq(uint8(reqAfter.status), uint8(IAmlEscrow.RequestStatus.Approved), "should be Approved after retry");

        (,, uint256 totalInvested,,,,,) = fundraise.projects(pid);
        assertEq(totalInvested, 200e6, "project totalInvested should be 200e6");
    }
}
