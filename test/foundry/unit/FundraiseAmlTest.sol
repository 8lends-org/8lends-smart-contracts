// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../Setup.sol";
import {AmlEscrow} from "../../../contracts/escrow/AmlEscrow.sol";
import {EscrowFactory} from "../../../contracts/escrow/EscrowFactory.sol";
import {IAmlEscrow} from "../../../contracts/escrow/interfaces/IAmlEscrow.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockUSDC.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Helper contract for D-19 cross-investor abuse test (test 5)
// ─────────────────────────────────────────────────────────────────────────────

interface IFundraiseAttack {
    function investFromEscrow(address investor, uint256 pid, uint256 amount, address inviter) external;
}

contract MaliciousContract {
    function attack(address _fundraise, address _victim, uint256 _pid, uint256 _amount, address _inviter) external {
        IFundraiseAttack(_fundraise).investFromEscrow(_victim, _pid, _amount, _inviter);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FundraiseAmlTest
// ─────────────────────────────────────────────────────────────────────────────

contract FundraiseAmlTest is Setup {
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
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _createEscrow(address _user) internal returns (AmlEscrow esc) {
        vm.prank(_user);
        esc = AmlEscrow(escrowFactory.createEscrow(_user));
    }

    function _escrowInvest(
        AmlEscrow esc,
        address _user,
        uint256 _pid,
        uint256 _amount,
        address _inv
    ) internal returns (uint256 reqId) {
        vm.prank(owner);
        usdc.mint(_user, _amount);
        vm.prank(_user);
        usdc.approve(address(esc), _amount);
        reqId = esc.getRequestCount();
        vm.prank(_user);
        esc.invest(_pid, _amount, _inv);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 — setAmlGateway: only owner
    // ─────────────────────────────────────────────────────────────────────────

    function test_SetAmlGateway_OnlyOwner() public {
        address newGateway = makeAddr("newGateway");
        vm.prank(attacker);
        // OwnableUpgradeable reverts with a custom error OwnableUnauthorizedAccount
        vm.expectRevert();
        fundraise.setAmlGateway(newGateway);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 — setAmlGateway: emits AmlGatewayUpdated
    // ─────────────────────────────────────────────────────────────────────────

    function test_SetAmlGateway_EmitsEvent() public {
        address newGateway = makeAddr("newGateway2");
        address oldGateway = fundraise.amlGateway();

        vm.expectEmit(true, true, false, false, address(fundraise));
        emit Fundraise.AmlGatewayUpdated(oldGateway, newGateway);

        vm.prank(owner);
        fundraise.setAmlGateway(newGateway);

        assertEq(fundraise.amlGateway(), newGateway, "amlGateway should be updated");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3 — setAmlGateway(address(0)) succeeds; subsequent investFromEscrow reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_SetAmlGateway_ZeroAddressAllowed() public {
        // Setting zero address should succeed
        vm.prank(owner);
        fundraise.setAmlGateway(address(0));
        assertEq(fundraise.amlGateway(), address(0), "amlGateway should be zero");

        // Create a project and escrow (escrowFactory still remembers the investor's escrow)
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // With amlGateway == address(0), investFromEscrow must revert "Not AML gateway"
        // approveInvest on the escrow will call investFromEscrow, which reverts
        vm.prank(backend);
        vm.expectRevert(Fundraise.NotAmlGateway.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4 — investFromEscrow: random EOA direct call reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_OnlyValidEscrow() public {
        uint256 pid = _createProject(100e6, 1000e6);

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAmlGateway.selector);
        fundraise.investFromEscrow(investor, pid, 100e6, inviter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5 — D-19: cross-investor abuse via malicious contract reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_CrossInvestorAbuse_Reverts() public {
        uint256 pid = _createProject(100e6, 1000e6);
        address victim = makeAddr("victim");

        // victim has a legitimate escrow registered
        _createEscrow(victim);

        // Malicious contract is NOT a registered escrow for victim
        MaliciousContract mal = new MaliciousContract();

        // The first check in investFromEscrow is "Not AML gateway" —
        // factory.escrows(victim) == victim's real escrow, not address(mal)
        vm.expectRevert(Fundraise.NotAmlGateway.selector);
        mal.attack(address(fundraise), victim, pid, 100e6, inviter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6 — amlGateway = zero → investFromEscrow reverts for any valid escrow
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_AmlGatewayZero_Reverts() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // Disable the gateway
        vm.prank(owner);
        fundraise.setAmlGateway(address(0));

        // approveInvest routes to escrow.approveInvest → investFromEscrow → reverts
        vm.prank(backend);
        vm.expectRevert(Fundraise.NotAmlGateway.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 7 — non-USDC loanToken reverts on approve
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_NonUsdcLoanToken_Reverts() public {
        MockUSDC otherToken = new MockUSDC();

        // Build project with otherToken as loanToken
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 1000e6,
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

        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.LoanTokenNotUsdc.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 8 — ComingSoon before startAt reverts on approve
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_ComingSoonBeforeStart_Reverts() public {
        // Project startAt = now + 1 day (not yet open)
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 1000e6,
            softCap: 100e6,
            totalInvested: 0,
            startAt: block.timestamp + 1 days,
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + 1 days + 7 days,
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
        uint256 pid = fundraise.createProject(proj, 1);

        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 100e6, inviter);

        // _invest returns false for ComingSoon before startAt; investFromEscrow requires(success)
        vm.prank(backend);
        vm.expectRevert(Fundraise.InvestmentFailed.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 9 — hardcap exceeded reverts on approve
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_HardcapExceeded_Reverts() public {
        // hardcap = 500e6, seed 400e6 via direct invest, then try 200e6 via escrow
        uint256 pid = _createProject(100e6, 500e6);

        // Seed 400e6 using the direct path
        _investAs(investor2, pid, 400e6, inviter);

        // Now investor tries 200e6 via escrow: 400 + 200 > 500 → exceeds hardcap
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 200e6, inviter);

        vm.prank(backend);
        vm.expectRevert(Fundraise.InvestmentExceedsHardCap.selector);
        escrowFactory.approveInvest(investor, reqId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 10 — happy path: records investor, emits Invest with investor address
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestFromEscrow_HappyPath_RecordsInvestor() public {
        uint256 pid = _createProject(100e6, 1000e6);
        AmlEscrow escrow = _createEscrow(investor);
        uint256 reqId = _escrowInvest(escrow, investor, pid, 300e6, inviter);

        // Pin emitter to fundraise contract; check all indexed + data fields
        vm.expectEmit(true, true, false, true, address(fundraise));
        emit Fundraise.Invest(pid, investor, 300e6);

        vm.prank(backend);
        escrowFactory.approveInvest(investor, reqId);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 300e6, "investedAmount should be 300e6");

        // Escrow address must have 0 invested
        (uint256 escrowInvested,) = fundraise.investorInfo(address(escrow), pid);
        assertEq(escrowInvested, 0, "escrow address should have 0 invested");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 11 — investUpdateV2 still works (backward compat regression)
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestUpdateV2_StillWorks() public {
        uint256 pid = _createProject(100e6, 1000e6);

        _investAs(investor, pid, 300e6, inviter);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, 300e6, "investedAmount should be 300e6");
        assertEq(fundraise.userNonces(investor), 1, "userNonce should be 1");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 12 — legacy investUpdate still works
    // ─────────────────────────────────────────────────────────────────────────

    function test_InvestUpdate_StillWorks() public {
        uint256 pid = _createProject(100e6, 1000e6);

        // Mint USDC to investor and approve Fundraise
        uint256 amount = 200e6;
        vm.prank(owner);
        usdc.mint(investor, amount);
        vm.prank(investor);
        usdc.approve(address(fundraise), amount);

        // Legacy signature: keccak256(abi.encodePacked(msg.sender, pid, amount, rootHash, nonce, inviter))
        // Global nonce is used; starts at 0, so next expected is 1
        uint256 legacyNonce = fundraise.nonce() + 1;
        bytes32 rootHash = bytes32(0);

        bytes32 innerHash = keccak256(
            abi.encodePacked(investor, pid, amount, rootHash, legacyNonce, inviter)
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 nonceBefore = fundraise.nonce();

        vm.prank(investor);
        fundraise.investUpdate(pid, amount, rootHash, legacyNonce, sig, inviter);

        (uint256 investedAmount,) = fundraise.investorInfo(investor, pid);
        assertEq(investedAmount, amount, "investedAmount should be recorded via investUpdate");
        assertEq(fundraise.nonce(), nonceBefore + 1, "global nonce should increment");
    }
}
