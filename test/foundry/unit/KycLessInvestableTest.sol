// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract KycLessInvestableTest is Setup {
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
    // GAP-044: valid project, under limit → true
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP044_kycLessInvestable_underLimit_true() public {
        // GAP-044: valid project, under limit → true
        uint256 pid = _createProject(100e6, 10_000e6);

        bool result = fundraise.kycLessInvestable(pid, investor, 300e6);
        assertTrue(result, "should be investable under limit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-045: valid project, over limit → false
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP045_kycLessInvestable_overLimit_false() public {
        // GAP-045: valid project, over limit → false
        uint256 pid = _createProject(100e6, 10_000e6);

        bool result = fundraise.kycLessInvestable(pid, investor, 501e6);
        assertFalse(result, "should not be investable over limit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-046: invalid pid → false
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP046_kycLessInvestable_invalidPid_false() public {
        // GAP-046: invalid pid → false
        uint256 invalidPid = 999;

        bool result = fundraise.kycLessInvestable(invalidPid, investor, 100e6);
        assertFalse(result, "should return false for invalid pid");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-047: consistent with actual investFromEscrow
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP047_kycLessInvestable_consistentWithEscrow() public {
        // GAP-047: consistent with actual investFromEscrow (both reject same overflows)
        uint256 pid = _createProject(100e6, 10_000e6);

        // Pre-invest 400 USDC via direct path
        _investAs(investor, pid, 400e6, inviter);

        // kycLessInvestable for 101 should return false
        bool result = fundraise.kycLessInvestable(pid, investor, 101e6);
        assertFalse(result, "kycLessInvestable should return false for 101 when at 400");

        // Actual investFromEscrow should also revert
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 101e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId);

        // kycLessInvestable for 100 should return true
        bool result2 = fundraise.kycLessInvestable(pid, investor, 100e6);
        assertTrue(result2, "kycLessInvestable should return true for 100 when at 400");
    }
}
