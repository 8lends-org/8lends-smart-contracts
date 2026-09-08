// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/interfaces/protocol/IAmlEscrow.sol";
import {IOracle} from "../../../contracts/interfaces/protocol/IOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract KycLessLimitTest is Setup {
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

    // ── Helpers ──

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

    function _escrowInvestAndApprove(
        AmlEscrow esc,
        address _user,
        uint256 _pid,
        uint256 _amount,
        address _inviter
    ) internal {
        uint256 reqId = _escrowInvest(esc, _user, _pid, _amount, _inviter);
        vm.prank(backend);
        escrowFactory.approveInvest(_user, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-001: investFromEscrow exact $500 (500e6 USDC) — should succeed
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP001_investFromEscrow_exact500_succeeds() public {
        // GAP-001: investFromEscrow exact $500 (500e6 USDC) — should succeed
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);

        _escrowInvestAndApprove(escrow, investor, pid, 500e6, inviter);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 500e6, "investor should have 500 USDC invested");
        assertEq(fundraise.allTimeInvestedUSD(investor), 500e6, "allTimeInvestedUSD should be 500e6");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-002: investFromEscrow $501 — revert KycLessLimitExceeded
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP002_investFromEscrow_501_reverts() public {
        // GAP-002: investFromEscrow $501 USDC — revert KycLessLimitExceeded
        // Note: factory max is 500e6 by default, so we must raise it first
        vm.prank(escrowFactory.owner());
        escrowFactory.setMaxInvestAmount(1000e6);

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 501e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-003: multi-tx $300 + $200 = $500 — succeed
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP003_multiTx_300_plus_200_succeeds() public {
        // GAP-003: multi-tx: $300 + $200 = $500 — succeed
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);

        _escrowInvestAndApprove(escrow, investor, pid, 300e6, inviter);
        _escrowInvestAndApprove(escrow, investor, pid, 200e6, inviter);

        assertEq(fundraise.allTimeInvestedUSD(investor), 500e6, "allTimeInvestedUSD should be 500e6");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-004: multi-tx $300 + $201 = $501 — revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP004_multiTx_300_plus_201_reverts() public {
        // GAP-004: multi-tx: $300 + $201 = $501 — revert
        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);

        _escrowInvestAndApprove(escrow, investor, pid, 300e6, inviter);

        uint256 reqId = _escrowInvest(escrow, investor, pid, 201e6, inviter);
        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-005: migrated allTimeInvestedUSD ($400) + escrow $101 — revert
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP005_migratedUSD_plus_escrow_reverts() public {
        // GAP-005: investor with migrated allTimeInvestedUSD ($400) + escrow $101 — revert
        address[] memory investors_ = new address[](1);
        investors_[0] = investor;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 400_000_000; // 400 USD in BASIS_POINTS scale

        vm.prank(manager);
        fundraise.migrateAllTimeInvestedUSD(investors_, amounts);
        assertEq(fundraise.allTimeInvestedUSD(investor), 400_000_000);

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 101e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-006: allTimeInvestedUSD from direct investUpdateV2 + escrow invest
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP006_directInvest_plus_escrow_limitEnforced() public {
        // GAP-006: investor with allTimeInvestedUSD from direct investUpdateV2 + escrow invest — limit enforced
        uint256 pid = _createProject(100e6, 10_000e6);

        // Direct invest 400 USDC
        _investAs(investor, pid, 400e6, inviter);
        assertEq(fundraise.allTimeInvestedUSD(investor), 400e6, "should have 400 USD tracked");

        // Try escrow invest 101 USDC — should exceed 500 limit
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 101e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-007: _toUSD with oracle: USDC amount → correct USD
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP007_toUSD_withOracle_correctConversion() public {
        // GAP-007: _toUSD with oracle: USDC amount → correct USD in BASIS_POINTS scale
        // Set oracle on fundraise: price = 1e8 for USDC (1 USD), priceDecimals = 8, tokenDecimals = 6
        // _toUSD(100e6, usdc) = mulDiv(100e6, 1e8 * 1e6, 10^(8+6)) = mulDiv(100e6, 1e14, 1e14) = 100e6
        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);

        _escrowInvestAndApprove(escrow, investor, pid, 100e6, inviter);

        assertEq(fundraise.allTimeInvestedUSD(investor), 100e6, "allTimeInvestedUSD should be 100e6 with oracle");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-008: _toUSD without oracle, USDC — 1:1 fallback
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP008_toUSD_noOracle_USDC_fallback() public {
        // GAP-008: _toUSD without oracle, USDC — 1:1 fallback
        // Oracle is not set on fundraise by default in Setup, so _toUSD falls back to 1:1 for USDC
        assertEq(fundraise.oracle(), address(0), "oracle should not be set");

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);

        _escrowInvestAndApprove(escrow, investor, pid, 250e6, inviter);

        assertEq(fundraise.allTimeInvestedUSD(investor), 250e6, "allTimeInvestedUSD should be 250e6 (1:1 USDC)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-009: _toUSD without oracle, non-USDC — revert OracleNotSet
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP009_toUSD_noOracle_nonUSDC_reverts() public {
        // GAP-009: _toUSD without oracle, non-USDC — revert OracleNotSet
        // investFromEscrow requires loanToken == USDC, so we can't test non-USDC via escrow path.
        // Instead, test via kycLessInvestable which also calls _toUSD internally.
        // Actually, investFromEscrow checks loanToken == usdc first, so non-USDC would revert LoanTokenNotUsdc.
        // The OracleNotSet revert is tested via _toUSD → kycLessInvestable with a non-USDC project.
        // But kycLessInvestable will also call _toUSD which will revert for non-USDC without oracle.
        // Let's test via direct investUpdateV2 with a non-USDC token — _tryToUSD returns 0,
        // so allTimeInvestedUSD won't increment.
        // For a pure _toUSD revert, we test via kycLessInvestable on a non-USDC project.

        // Create a project with non-USDC loanToken
        MockUSDC otherToken = new MockUSDC();
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 10_000e6,
            softCap: 100e6,
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
                loanToken: IERC20(address(otherToken)),
                stage: Fundraise.Stage.ComingSoon
            })
        });
        vm.prank(manager);
        uint256 pid = fundraise.createProject(proj, 1);

        // kycLessInvestable calls _toUSD which should revert OracleNotSet for non-USDC
        vm.expectRevert(Fundraise.OracleNotSet.selector);
        fundraise.kycLessInvestable(pid, investor, 100e6);
    }
}
