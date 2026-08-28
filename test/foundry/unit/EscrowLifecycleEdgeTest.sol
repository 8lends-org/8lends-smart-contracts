// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/interfaces/protocol/IAmlEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EscrowLifecycleEdgeTest is Setup {
    AmlEscrow public escrowImpl;
    EscrowFactory public escrowFactory;

    function setUp() public override {
        super.setUp();

        escrowImpl = new AmlEscrow();
        EscrowFactory factoryImpl = new EscrowFactory();
        bytes memory initData = abi.encodeCall(
            EscrowFactory.initialize,
            (address(escrowImpl), address(fundraise), address(usdc), backend)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        escrowFactory = EscrowFactory(address(proxy));

        vm.prank(owner);
        fundraise.setAmlGateway(address(escrowFactory));
    }

    function _createEscrow(address _user) internal returns (AmlEscrow esc) {
        vm.prank(_user);
        esc = AmlEscrow(escrowFactory.createEscrow(_user));
    }

    function _escrowInvest(
        AmlEscrow esc,
        address _user,
        uint256 _pid,
        uint256 _amount,
        address _inviter
    ) internal returns (uint256 reqId) {
        vm.prank(owner);
        usdc.mint(_user, _amount);
        vm.prank(_user);
        usdc.approve(address(esc), _amount);
        reqId = esc.getRequestCount();
        vm.prank(_user);
        esc.invest(_pid, _amount, _inviter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-048: cancelRequest at exact boundary (block.timestamp == cancelAfter)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP048_cancelRequest_exactBoundary_succeeds() public {
        // GAP-048: cancelRequest at exact boundary (block.timestamp == cancelAfter) → succeed
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        IAmlEscrow.InvestRequest memory req = escrow.getRequest(reqId);
        uint256 cancelAfter = req.cancelAfter;

        // Warp to exactly cancelAfter
        vm.warp(cancelAfter);

        vm.prank(investor);
        escrow.cancelRequest(reqId);

        IAmlEscrow.InvestRequest memory reqAfter = escrow.getRequest(reqId);
        assertEq(uint8(reqAfter.status), uint8(IAmlEscrow.RequestStatus.Cancelled));
        assertEq(usdc.balanceOf(investor), 100e6, "USDC should be returned");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-049: approveInvest after cancelRequest → revert "Not pending"
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP049_approveAfterCancel_reverts() public {
        // GAP-049: approveInvest after cancelRequest → revert "Not pending"
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Cancel
        IAmlEscrow.InvestRequest memory req = escrow.getRequest(reqId);
        vm.warp(req.cancelAfter);
        vm.prank(investor);
        escrow.cancelRequest(reqId);

        // Try approve
        vm.prank(backend);
        vm.expectRevert(bytes("Not pending"));
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-050: rejectInvest after cancelRequest → revert "Not pending"
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP050_rejectAfterCancel_reverts() public {
        // GAP-050: rejectInvest after cancelRequest → revert "Not pending"
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        IAmlEscrow.InvestRequest memory req = escrow.getRequest(reqId);
        vm.warp(req.cancelAfter);
        vm.prank(investor);
        escrow.cancelRequest(reqId);

        vm.prank(backend);
        vm.expectRevert(bytes("Not pending"));
        escrowFactory.rejectInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-051: approveInvest after rejectInvest → revert "Not pending"
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP051_approveAfterReject_reverts() public {
        // GAP-051: approveInvest after rejectInvest → revert "Not pending"
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Reject
        vm.prank(backend);
        escrowFactory.rejectInvest(investor, reqId);

        // Try approve
        vm.prank(backend);
        vm.expectRevert(bytes("Not pending"));
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-052: residual allowance after approveInvest == 0
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP052_residualAllowance_isZero() public {
        // GAP-052: residual allowance: after approveInvest, usdc.allowance(escrow, fundraise) == 0
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        uint256 allowance = usdc.allowance(address(escrow), address(fundraise));
        assertEq(allowance, 0, "residual allowance should be 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-053: partial consumption — verify allowance reset
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP053_allowanceResetAfterApproval() public {
        // GAP-053: partial consumption scenario: verify allowance reset
        // In practice investFromEscrow always consumes exact amount via safeTransferFrom,
        // but the escrow does forceApprove(0) after the call regardless.
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 200e6, inviter);

        // Before approval, check escrow USDC balance
        assertEq(usdc.balanceOf(address(escrow)), 200e6, "escrow should hold 200e6");

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        // After approval: escrow empty, allowance 0
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow should be empty");
        assertEq(usdc.allowance(address(escrow), address(fundraise)), 0, "allowance should be 0");
    }
}
