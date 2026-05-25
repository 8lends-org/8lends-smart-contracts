// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MigrateAllTimeInvestedUSDTest is Setup {
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
    // GAP-033: happy path — values added correctly
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP033_migrateHappyPath() public {
        // GAP-033: happy path: values added correctly
        address[] memory investors_ = new address[](2);
        investors_[0] = investor;
        investors_[1] = investor2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100_000_000; // 100 USD
        amounts[1] = 200_000_000; // 200 USD

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);

        assertEq(fundraise.allTimeInvestedUSD(investor), 100_000_000);
        assertEq(fundraise.allTimeInvestedUSD(investor2), 200_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-034: repeated call — idempotent set (overwrites, not additive)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP034_migrateRepeated_idempotent() public {
        // GAP-034: repeated call with same value → idempotent (contract uses = not +=)
        address[] memory investors_ = new address[](1);
        investors_[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);
        assertEq(fundraise.allTimeInvestedUSD(investor), 100_000_000);

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);
        assertEq(fundraise.allTimeInvestedUSD(investor), 100_000_000, "should overwrite (idempotent) on repeated call");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-035: empty arrays — succeed, emit count=0
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP035_migrateEmptyArrays() public {
        // GAP-035: empty arrays: succeed, emit count=0
        address[] memory investors_ = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectEmit(false, false, false, true, address(fundraise));
        emit Fundraise.AllTimeInvestedUSDMigrated(0);

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-036: array length mismatch — revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP036_migrateMismatch_reverts() public {
        // GAP-036: array length mismatch: revert ArrayLengthMismatch
        address[] memory investors_ = new address[](2);
        investors_[0] = investor;
        investors_[1] = investor2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(manager);
        vm.expectRevert(Fundraise.ArrayLengthMismatch.selector);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-037: address(0) in array — no revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP037_migrateAddressZero_noRevert() public {
        // GAP-037: address(0) in array: no revert, sets allTimeInvestedUSD[address(0)]
        address[] memory investors_ = new address[](1);
        investors_[0] = address(0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);

        assertEq(fundraise.allTimeInvestedUSD(address(0)), 100_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-038: non-manager — revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP038_migrateNonManager_reverts() public {
        // GAP-038: non-manager: revert NotAManager
        address[] memory investors_ = new address[](1);
        investors_[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-039: after migration, investFromEscrow respects new limit
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP039_afterMigration_escrowRespectsLimit() public {
        // GAP-039: after migration, investFromEscrow respects new limit
        // Migrate 490 USD
        address[] memory investors_ = new address[](1);
        investors_[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 490_000_000;

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);

        // 10 USDC should fit (490 + 10 = 500)
        uint256 reqId1 = _escrowInvest(escrow, investor, pid, 10e6, inviter);
        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId1);
        assertEq(fundraise.allTimeInvestedUSD(investor), 500_000_000);

        // 1 more USDC should fail (500 + 1 > 500)
        uint256 reqId2 = _escrowInvest(escrow, investor, pid, 1e6, inviter);
        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId2);
    }
}
