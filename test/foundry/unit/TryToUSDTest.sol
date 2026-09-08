// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IOracle} from "../../../contracts/interfaces/protocol/IOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockUSDC.sol";

contract TryToUSDTest is Setup {
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
    // GAP-017: _tryToUSD oracle set → returns _toUSD value (> 0)
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP017_tryToUSD_oracleSet_returnsValue() public {
        // GAP-017: _tryToUSD: oracle set → returns _toUSD value (> 0)
        // Tested via investUpdateV2: allTimeInvestedUSD should be > 0
        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));

        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 100e6, inviter);

        // With oracle, USDC price = 1e8, so _toUSD(100e6) = 100e6
        assertGt(fundraise.allTimeInvestedUSD(investor), 0, "allTimeInvestedUSD should be > 0");
        assertEq(fundraise.allTimeInvestedUSD(investor), 100e6, "should equal 100e6");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-018: _tryToUSD no oracle, USDC → returns _amount
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP018_tryToUSD_noOracle_USDC_returnsAmount() public {
        // GAP-018: _tryToUSD: no oracle, USDC → returns _amount
        assertEq(fundraise.oracle(), address(0));

        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 250e6, inviter);

        assertEq(fundraise.allTimeInvestedUSD(investor), 250e6, "should be 250e6 (1:1)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-019: _tryToUSD no oracle, non-USDC → returns 0
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP019_tryToUSD_noOracle_nonUSDC_returns0() public {
        // GAP-019: _tryToUSD: no oracle, non-USDC → returns 0
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

        vm.prank(owner);
        otherToken.mint(investor, 100e6);
        vm.prank(investor);
        otherToken.approve(address(fundraise), 100e6);

        uint256 nonce = fundraise.userNonces(investor) + 1;
        bytes memory sig = _signInvest(investor, pid, 100e6, nonce, inviter);
        vm.prank(investor);
        fundraise.investUpdateV2(pid, 100e6, nonce, sig, inviter);

        assertEq(fundraise.allTimeInvestedUSD(investor), 0, "should be 0 for non-USDC without oracle");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-020: _tryToUSD no oracle, rewardSystem == address(0) → returns 0
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP020_tryToUSD_noOracle_noRewardSystem_returns0() public {
        // GAP-020: _tryToUSD: no oracle, rewardSystem == address(0) → returns 0
        // Set rewardSystem to 0 so the USDC check in _tryToUSD can't resolve
        vm.prank(owner);
        fundraise.setRewardSystem(address(0));

        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 100e6, inviter);

        // _tryToUSD: oracle == 0, rewardSystem == 0 → returns 0
        assertEq(fundraise.allTimeInvestedUSD(investor), 0, "should be 0 when rewardSystem is zero");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-021: _toUSD oracle price == 0 → revert LoanTokenPriceZero
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP021_toUSD_oraclePriceZero_reverts() public {
        // GAP-021: _toUSD: oracle price == 0 → revert LoanTokenPriceZero
        // Set oracle with zero price for USDC
        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));
        mockOracle.setPrice(address(usdc), 0);

        uint256 pid = _createProject(100e6, 10_000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // investFromEscrow calls _toUSD which should revert
        vm.prank(backend);
        vm.expectRevert(Fundraise.LoanTokenPriceZero.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-022: _toUSD Math.mulDiv with large values — no overflow
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP022_toUSD_largeValues_noOverflow() public {
        // GAP-022: _toUSD: Math.mulDiv with large values — no overflow
        // Set oracle with very high price
        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));
        mockOracle.setPrice(address(usdc), type(uint128).max); // huge price

        uint256 pid = _createProject(100e6, 10_000e6);

        // This should not overflow thanks to Math.mulDiv
        // investFromEscrow path will compute _toUSD and either succeed or revert due to limit,
        // but should NOT revert with arithmetic overflow
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 1e6, inviter);

        // The computation: mulDiv(1e6, uint128.max * 1e6, 1e14)
        // = 1e6 * uint128.max * 1e6 / 1e14 = uint128.max / 1e2
        // This is a huge number, so it will exceed KYC limit, but no overflow
        vm.prank(backend);
        vm.expectRevert(Fundraise.KycLessLimitExceeded.selector);
        escrowFactory.approveInvest(investor, reqId);
        // If we get here (revert with KycLessLimitExceeded, not overflow), the test passes
    }
}
