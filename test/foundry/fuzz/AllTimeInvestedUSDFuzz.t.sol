// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AllTimeInvestedUSDFuzz is Setup {
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
    // GAP-071: Fuzz: allTimeInvestedUSD monotonically increases with invests
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP071_fuzz_allTimeInvestedUSD_monotonic(uint256 amount1, uint256 amount2) public {
        // GAP-071: Fuzz: allTimeInvestedUSD monotonically increases with invests
        // Bound amounts to reasonable range: 1 USDC to 1M USDC
        amount1 = bound(amount1, 1e6, 1_000_000e6);
        amount2 = bound(amount2, 1e6, 1_000_000e6);

        // Create project with huge hardcap
        uint256 pid = _createProject(1e6, type(uint128).max);

        _investAs(investor, pid, amount1, inviter);
        uint256 usdAfterFirst = fundraise.allTimeInvestedUSD(investor);
        assertEq(usdAfterFirst, amount1, "should match first invest");

        _investAs(investor, pid, amount2, inviter);
        uint256 usdAfterSecond = fundraise.allTimeInvestedUSD(investor);
        assertGe(usdAfterSecond, usdAfterFirst, "allTimeInvestedUSD must be monotonically non-decreasing");
        assertEq(usdAfterSecond, amount1 + amount2, "should equal sum");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-072: Fuzz: withdrawInvestment never underflows allTimeInvestedUSD
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP072_fuzz_withdrawNeverUnderflows(uint256 amount) public {
        // GAP-072: Fuzz: withdrawInvestment never underflows allTimeInvestedUSD
        amount = bound(amount, 1e6, 10_000_000e6);

        uint256 pid = _createProject(1e6, type(uint128).max);
        _investAs(investor, pid, amount, inviter);

        uint256 usdBefore = fundraise.allTimeInvestedUSD(investor);
        assertGt(usdBefore, 0);

        vm.prank(manager);
        fundraise.cancelProject(pid);

        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);

        uint256 usdAfter = fundraise.allTimeInvestedUSD(investor);
        // Should never underflow — either 0 or a positive value
        assertLe(usdAfter, usdBefore, "should not increase after withdraw");
        // With USDC 1:1 and no oracle, it should be exactly 0
        assertEq(usdAfter, 0, "should be 0 for USDC 1:1 withdraw");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-073: Fuzz: investFromEscrow random amounts vs KYC cap
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP073_fuzz_investFromEscrow_kycCap(uint256 amount) public {
        // GAP-073: Fuzz: investFromEscrow random amounts vs KYC cap
        // Factory limits: min=1e6, max=500e6
        amount = bound(amount, 1e6, 500e6);

        uint256 pid = _createProject(1e6, type(uint128).max);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, amount, inviter);

        uint256 maxKycLess = 500_000_000; // MAX_KYC_LESS_INVEST_USD

        if (amount <= maxKycLess) {
            // Should succeed
            vm.prank(backend);
            escrowFactory.approveInvest(investor, reqId);

            assertEq(fundraise.allTimeInvestedUSD(investor), amount);
        } else {
            // Should revert (unreachable given bound, but defensive)
            vm.prank(backend);
            vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
            escrowFactory.approveInvest(investor, reqId);
        }
    }
}
