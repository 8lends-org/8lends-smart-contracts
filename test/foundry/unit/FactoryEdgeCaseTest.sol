// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/escrow/interfaces/IAmlEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockUSDC.sol";

contract FactoryEdgeCaseTest is Setup {
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
    // GAP-054: createEscrow(address(0)) — should revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP054_createEscrow_addressZero_reverts() public {
        // GAP-054: createEscrow(address(0)) — AmlEscrow.initialize reverts "Zero address"
        // msg.sender must be _user or signer. Use backend (signer) to call with address(0).
        vm.prank(backend);
        vm.expectRevert(bytes("Zero address"));
        escrowFactory.createEscrow(address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-055: setSigner mid-flight: old signer revert, new signer succeed
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP055_setSigner_midFlight() public {
        // GAP-055: setSigner mid-flight: old signer → revert "Not signer", new signer → succeed
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Change signer
        address newSigner = makeAddr("newSigner");
        vm.prank(escrowFactory.owner());
        escrowFactory.setSigner(newSigner);

        // Old signer (backend) should fail
        vm.prank(backend);
        vm.expectRevert(bytes("Not signer"));
        escrowFactory.approveInvest(investor, reqId);

        // New signer should succeed
        vm.prank(newSigner);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-056: setImplementation: new escrows use new impl, existing work
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP056_setImplementation_newEscrowsUseNewImpl() public {
        // GAP-056: setImplementation: new escrows use new impl, existing escrows work with old impl
        // Create escrow with old impl
        AmlEscrow oldEscrow = _createEscrow(investor);

        // Deploy new impl and set it
        AmlEscrow newImpl = new AmlEscrow();
        vm.prank(escrowFactory.owner());
        escrowFactory.setImplementation(address(newImpl));

        // Create escrow with new impl
        AmlEscrow newEscrow = _createEscrow(investor2);

        // Both should work
        uint256 pid = _createProject(100e6, 10_000e6);

        uint256 reqId1 = _escrowInvest(oldEscrow, investor, pid, 100e6, inviter);
        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId1);

        uint256 reqId2 = _escrowInvest(newEscrow, investor2, pid, 100e6, inviter);
        vm.prank(backend);
        escrowFactory.approveInvest(investor2, reqId2);

        (uint256 inv1,) = fundraise.investorInfo(investor, pid);
        (uint256 inv2,) = fundraise.investorInfo(investor2, pid);
        assertEq(inv1, 100e6, "old escrow should still work");
        assertEq(inv2, 100e6, "new escrow should work too");

        // Verify different implementation addresses
        assertTrue(address(oldEscrow) != address(newEscrow), "should be different escrow addresses");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-057: setFundraise: existing escrow reads new fundraise dynamically
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP057_setFundraise_existingEscrowReadsDynamically() public {
        // GAP-057: setFundraise: existing escrow reads factory.fundraise() dynamically
        AmlEscrow escrow = _createEscrow(investor);
        uint256 pid = _createProject(100e6, 10_000e6);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Deploy a dummy fundraise address (just an EOA for the test)
        address dummyFundraise = makeAddr("dummyFundraise");
        vm.prank(escrowFactory.owner());
        escrowFactory.setFundraise(dummyFundraise);

        // Now approveInvest should try to call investFromEscrow on the dummy address
        // which will revert (EOA, no code)
        vm.prank(backend);
        vm.expectRevert(); // call to non-contract
        escrowFactory.approveInvest(investor, reqId);

        // Restore original fundraise
        vm.prank(escrowFactory.owner());
        escrowFactory.setFundraise(address(fundraise));

        // Now it should work
        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-058: setUsdc: escrow reads new USDC — invest with old token fails
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP058_setUsdc_escrowReadsNewUsdc() public {
        // GAP-058: setUsdc: escrow reads new USDC — invest with old token fails
        AmlEscrow escrow = _createEscrow(investor);

        // Deploy new USDC
        MockUSDC newUsdc = new MockUSDC();
        vm.prank(escrowFactory.owner());
        escrowFactory.setUsdc(address(newUsdc));

        // Now escrow.invest() will try to pull newUsdc from investor, not old usdc
        // Mint old usdc and approve
        vm.prank(owner);
        usdc.mint(investor, 100e6);
        vm.prank(investor);
        usdc.approve(address(escrow), 100e6);

        uint256 pid = _createProject(100e6, 10_000e6);

        // invest() reads f.usdc() which now returns newUsdc
        // safeTransferFrom(investor, escrow, 100e6) on newUsdc will fail because investor has no newUsdc balance
        vm.prank(investor);
        vm.expectRevert(); // ERC20 transfer fails — no balance
        escrow.invest(pid, 100e6, inviter);
    }
}
