// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/interfaces/protocol/IAmlEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockUSDC.sol";

contract AllTimeInvestedUSDTest is Setup {
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

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-010: _invest via investUpdateV2: allTimeInvestedUSD incremented
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP010_investUpdateV2_incrementsAllTimeInvestedUSD() public {
        // GAP-010: _invest via investUpdateV2: allTimeInvestedUSD incremented
        uint256 pid = _createProject(100e6, 10_000e6);

        assertEq(fundraise.allTimeInvestedUSD(investor), 0, "should start at 0");

        _investAs(investor, pid, 300e6, inviter);

        assertEq(fundraise.allTimeInvestedUSD(investor), 300e6, "allTimeInvestedUSD should be 300e6");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-011: _invest non-USDC without oracle: allTimeInvestedUSD NOT incremented
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP011_investNonUSDC_noOracle_notIncremented() public {
        // GAP-011: _invest non-USDC without oracle: allTimeInvestedUSD NOT incremented
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

        // Mint otherToken and invest directly
        vm.prank(owner);
        otherToken.mint(investor, 500e6);
        vm.prank(investor);
        otherToken.approve(address(fundraise), 500e6);

        uint256 currentNonce = fundraise.userNonces(investor);
        uint256 nonceForSig = currentNonce + 1;
        bytes memory sig = _signInvest(investor, pid, 500e6, nonceForSig, inviter);

        vm.prank(investor);
        fundraise.investUpdateV2(pid, 500e6, nonceForSig, sig, inviter);

        // _tryToUSD returns 0 for non-USDC without oracle → allTimeInvestedUSD not incremented
        assertEq(fundraise.allTimeInvestedUSD(investor), 0, "allTimeInvestedUSD should remain 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-012: withdrawInvestment: allTimeInvestedUSD decremented correctly
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP012_withdrawInvestment_decrementsAllTimeInvestedUSD() public {
        // GAP-012: withdrawInvestment: allTimeInvestedUSD decremented correctly
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 300e6, inviter);
        assertEq(fundraise.allTimeInvestedUSD(investor), 300e6);

        // Cancel the project
        vm.prank(manager);
        fundraise.cancelProject(pid);

        // Withdraw
        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);

        assertEq(fundraise.allTimeInvestedUSD(investor), 0, "allTimeInvestedUSD should be 0 after withdraw");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-013: withdrawInvestment: underflow protection
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP013_withdrawInvestment_underflowProtection() public {
        // GAP-013: withdrawInvestment: underflow protection — allTimeInvestedUSD < usdValue → clamp to 0
        // Invest with oracle set (so _tryToUSD uses oracle price), then remove oracle before withdraw
        // so that at withdraw time _tryToUSD returns the amount 1:1 which may be > allTimeInvestedUSD
        // Actually, simpler: invest with oracle giving low price, then change price to high before withdraw.

        // Step 1: Set oracle with low price (0.5 USD = 5e7 in 8 decimals)
        vm.startPrank(owner);
        fundraise.setOracle(address(mockOracle));
        vm.stopPrank();
        mockOracle.setPrice(address(usdc), 5e7); // 0.5 USD

        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 300e6, inviter);

        // allTimeInvestedUSD = mulDiv(300e6, 5e7 * 1e6, 10^14) = mulDiv(300e6, 5e13, 1e14) = 150e6
        assertEq(fundraise.allTimeInvestedUSD(investor), 150e6, "should be 150e6 at 0.5 price");

        // Step 2: Change price to 2 USD before withdraw
        mockOracle.setPrice(address(usdc), 2e8); // 2 USD

        // Cancel and withdraw
        vm.prank(manager);
        fundraise.cancelProject(pid);

        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);

        // _tryToUSD at 2 USD: mulDiv(300e6, 2e8 * 1e6, 1e14) = mulDiv(300e6, 2e14, 1e14) = 600e6
        // 150e6 < 600e6 → clamp to 0
        assertEq(fundraise.allTimeInvestedUSD(investor), 0, "should clamp to 0 on underflow");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-014: withdrawInvestment: oracle price changed — asymmetric
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP014_withdrawInvestment_priceChanged_asymmetric() public {
        // GAP-014: withdrawInvestment: oracle price changed between invest and withdraw
        vm.prank(owner);
        fundraise.setOracle(address(mockOracle));

        // Invest at price = 1 USD
        mockOracle.setPrice(address(usdc), 1e8);
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 200e6, inviter);
        assertEq(fundraise.allTimeInvestedUSD(investor), 200e6);

        // Change price to 0.8 USD before withdraw
        mockOracle.setPrice(address(usdc), 8e7); // 0.8 USD

        vm.prank(manager);
        fundraise.cancelProject(pid);

        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);

        // _tryToUSD at 0.8: mulDiv(200e6, 8e7 * 1e6, 1e14) = mulDiv(200e6, 8e13, 1e14) = 160e6
        // 200e6 - 160e6 = 40e6 remaining
        assertEq(fundraise.allTimeInvestedUSD(investor), 40e6, "asymmetric: should have 40e6 remaining");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-015: transferInvestment: allTimeInvestedUSD NOT transferred
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP015_transferInvestment_allTimeInvestedUSD_notTransferred() public {
        // GAP-015: transferInvestment: allTimeInvestedUSD NOT transferred
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 300e6, inviter);

        // Fund the project so we can do transferInvestment (requires Funded stage for sell)
        _investAs(investor2, pid, 9700e6, inviter); // fill to softcap
        _fundProject(pid);

        uint256 usdBefore = fundraise.allTimeInvestedUSD(investor);
        assertEq(usdBefore, 300e6);
        assertEq(fundraise.allTimeInvestedUSD(investor2), 9700e6);

        address market = makeAddr("market");
        vm.prank(owner);
        managerRegistry.setMarketAddress(market);

        vm.prank(market);
        fundraise.transferInvestment(pid, investor, attacker, true, 1);

        // allTimeInvestedUSD should NOT change for either party
        assertEq(fundraise.allTimeInvestedUSD(investor), usdBefore, "from: allTimeInvestedUSD unchanged");
        assertEq(fundraise.allTimeInvestedUSD(attacker), 0, "to: allTimeInvestedUSD should be 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GAP-016: transferPosition: allTimeInvestedUSD not affected
    // ─────────────────────────────────────────────────────────────────────────

    function test_GAP016_transferPosition_allTimeInvestedUSD_notAffected() public {
        // GAP-016: transferPosition: same — allTimeInvestedUSD not affected
        uint256 pid = _createProject(100e6, 10_000e6);
        _investAs(investor, pid, 300e6, inviter);
        _investAs(investor2, pid, 9700e6, inviter);
        _fundProject(pid);

        uint256 usdBefore = fundraise.allTimeInvestedUSD(investor);

        address market = makeAddr("market2");
        vm.prank(owner);
        managerRegistry.setMarketAddress(market);

        vm.prank(market);
        fundraise.transferPosition(pid, investor, attacker, 0, 1);

        assertEq(fundraise.allTimeInvestedUSD(investor), usdBefore, "from: allTimeInvestedUSD unchanged");
        assertEq(fundraise.allTimeInvestedUSD(attacker), 0, "to: allTimeInvestedUSD should be 0");
    }
}
