// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FundraiseOracleSetterTest is Setup {
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
    // GAP-040: setOracle(0) → revert ZeroAddress
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP040_setOracle_zeroAddress_reverts() public {
        // GAP-040: setOracle(0) → revert ZeroAddress
        vm.prank(owner);
        vm.expectRevert(Fundraise.ZeroAddress.selector);
        fundraise.setOracle(address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-041: setOracle non-owner → revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP041_setOracle_nonOwner_reverts() public {
        // GAP-041: setOracle non-owner → revert
        vm.prank(attacker);
        vm.expectRevert();
        fundraise.setOracle(address(mockOracle));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-042: setOracle happy: stores, emits OracleUpdated
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP042_setOracle_happyPath() public {
        // GAP-042: setOracle happy: stores, emits OracleUpdated
        vm.expectEmit(false, false, false, true, address(fundraise));
        emit Fundraise.OracleUpdated(address(mockOracle));

        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));

        assertEq(fundraise.oracle(), address(mockOracle), "oracle should be set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-043: invest after setOracle: allTimeInvestedUSD calculated via oracle
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP043_investAfterSetOracle_usesOracle() public {
        // GAP-043: invest after setOracle: allTimeInvestedUSD calculated via oracle
        // mockOracle has USDC price = 1e8 (1 USD)
        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));

        uint256 pid = _createProject(100e6, 10_000e6);

        // Invest via escrow
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 200e6, inviter);
        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        // _toUSD with oracle: mulDiv(200e6, 1e8 * 1e6, 10^14) = 200e6
        assertEq(fundraise.allTimeInvestedUSD(investor), 200e6, "should use oracle for USD conversion");
    }
}
