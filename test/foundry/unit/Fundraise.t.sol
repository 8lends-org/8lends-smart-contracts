// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";

contract FundraiseTest is Setup {
    uint256 pid;

    function setUp() public override {
        super.setUp();
        // Create a default project: softCap=20k, hardCap=40k USDC
        pid = _createProject(20_000e6, 40_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    LIFECYCLE / STATE MACHINE
    // ═══════════════════════════════════════════════════════════════

    function test_createProject_setsComingSoonStage() public view {
        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.ComingSoon));
    }

    function test_invest_transitionsComingSoonToOpen() public {
        // Project startAt is block.timestamp - 10, so first invest transitions to Open
        _investAs(investor, pid, 5_000e6, inviter);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Open));
    }

    function test_invest_transitionsToPreFunded_whenHardCapReached() public {
        _investAs(investor, pid, 40_000e6, inviter);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.PreFunded));
    }

    function test_invest_transitionsToCanceled_whenExpiredBelowSoftCap() public {
        // Invest below softCap
        _investAs(investor, pid, 10_000e6, inviter);

        // Warp past openStageEndAt
        vm.warp(block.timestamp + 8 days);

        // Next invest triggers stage check → Canceled
        // Need to prepare a new invest attempt that triggers the check
        vm.prank(owner);
        usdc.mint(investor2, 1_000e6);
        vm.prank(investor2);
        usdc.approve(address(fundraise), 1_000e6);

        uint256 currentNonce = fundraise.userNonces(investor2);
        bytes memory sig = _signInvest(investor2, pid, 1_000e6, currentNonce + 1, address(0));

        // This invest call will trigger the Canceled transition and return silently
        vm.prank(investor2);
        fundraise.investUpdateV2(pid, 1_000e6, currentNonce + 1, sig, address(0));

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Canceled));
    }

    function test_transferFundsToBorrower_transitionsToFunded() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Funded));
    }

    function test_makeRepayment_transitionsToRepaid_whenFull() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Repaid));
    }

    // ═══════════════════════════════════════════════════════════════
    //    T-09: NONCE UNCHANGED ON FAILED INVEST
    // ═══════════════════════════════════════════════════════════════

    function test_nonceUnchanged_comingSoonBeforeStart() public {
        // Create project that hasn't started yet (startAt in the future)
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 40_000e6,
            softCap: 20_000e6,
            totalInvested: 0,
            startAt: block.timestamp + 1 days, // FUTURE
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + 8 days,
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
        uint256 futurePid = fundraise.createProject(proj, 2);

        uint256 nonceBefore = fundraise.userNonces(investor);

        // Prepare invest
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 nonceForSig = nonceBefore + 1;
        bytes memory sig = _signInvest(investor, futurePid, 5_000e6, nonceForSig, inviter);

        vm.prank(investor);
        fundraise.investUpdateV2(futurePid, 5_000e6, nonceForSig, sig, inviter);

        // FIX: nonce must NOT be incremented when _invest returns early
        assertEq(fundraise.userNonces(investor), nonceBefore, "Nonce must not change on failed invest");

        // No tokens were transferred from investor
        (,, uint256 totalInvested,,,,,) = fundraise.projects(futurePid);
        assertEq(totalInvested, 0, "No actual investment happened");
    }

    function test_nonceUpdated_onSuccessfulInvest() public {
        uint256 nonceBefore = fundraise.userNonces(investor);

        // Prepare invest
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 nonceForSig = nonceBefore + 1;
        bytes memory sig = _signInvest(investor, pid, 5_000e6, nonceForSig, inviter);

        vm.prank(investor);
        fundraise.investUpdateV2(pid, 5_000e6, nonceForSig, sig, inviter);

        // Nonce must be incremented on successful invest
        assertEq(fundraise.userNonces(investor), nonceBefore + 1, "Nonce must be incremented on successful invest");

        // Investment actually happened
        (,, uint256 totalInvested,,,,,) = fundraise.projects(pid);
        assertEq(totalInvested, 5_000e6, "Investment should be recorded");
    }

    // ═══════════════════════════════════════════════════════════════
    //      VULNERABILITY #2 FIX: PER-USER NONCES ALLOW CONCURRENT INVESTS
    // ═══════════════════════════════════════════════════════════════

    function test_vuln2_perUserNonce_bothInvestorsSucceed() public {
        // Each investor uses their own nonce (both start at 0, so nonceForSig = 1)
        uint256 nonce1 = fundraise.userNonces(investor) + 1;
        uint256 nonce2 = fundraise.userNonces(investor2) + 1;

        // Investor 1 prepares and sends
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);
        bytes memory sig1 = _signInvest(investor, pid, 5_000e6, nonce1, inviter);

        // Investor 2 prepares with their own nonce (same value, different user)
        vm.prank(owner);
        usdc.mint(investor2, 3_000e6);
        vm.prank(investor2);
        usdc.approve(address(fundraise), 3_000e6);
        bytes memory sig2 = _signInvest(investor2, pid, 3_000e6, nonce2, inviter);

        // Investor 1 succeeds
        vm.prank(investor);
        fundraise.investUpdateV2(pid, 5_000e6, nonce1, sig1, inviter);

        // Investor 2 also succeeds — per-user nonces are independent
        vm.prank(investor2);
        fundraise.investUpdateV2(pid, 3_000e6, nonce2, sig2, inviter);

        // Verify both investments were recorded
        (uint256 invested1,) = fundraise.investorInfo(investor, pid);
        (uint256 invested2,) = fundraise.investorInfo(investor2, pid);
        assertEq(invested1, 5_000e6, "Investor 1 investment recorded");
        assertEq(invested2, 3_000e6, "Investor 2 investment recorded");
    }

    // ═══════════════════════════════════════════════════════════════
    //                     CLAIM MATH + DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════

    function test_claim_singleInvestor_getsExactRepayment() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        uint256 balAfter = usdc.balanceOf(investor);

        // Single investor should get everything repaid
        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(balAfter - balBefore, inner.totalRepaid);
    }

    function test_claim_twoInvestors_proportionalDistribution() public {
        // Investor1: 10k, Investor2: 30k → 25% / 75%
        _investAs(investor, pid, 10_000e6, inviter);
        _investAs(investor2, pid, 30_000e6, address(0));
        _fundProject(pid);
        _repayFull(pid);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        uint256 totalRepaid = inner.totalRepaid;

        vm.prank(investor);
        fundraise.claim(pid, investor);
        vm.prank(investor2);
        fundraise.claim(pid, investor2);

        (,uint256 claimed1) = fundraise.investorInfo(investor, pid);
        (,uint256 claimed2) = fundraise.investorInfo(investor2, pid);

        // Sum of claims should not exceed totalRepaid
        assertLe(claimed1 + claimed2, totalRepaid, "Over-claim detected");
        // Each claim should be roughly proportional
        assertGt(claimed2, claimed1, "Larger investor should claim more");
    }

    function test_claim_partialRepayment() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);

        // Repay 50%
        (,, uint256 totalInvested,,,,,) = fundraise.projects(pid);
        _repay(pid, totalInvested / 2);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        uint256 claimed = usdc.balanceOf(investor) - balBefore;

        // Should get roughly half of total repaid
        assertGt(claimed, 0);
        assertLe(claimed, totalInvested / 2);
    }

    function test_claim_noDoubleClaimOnSameRepayment() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repay(pid, 15_000e6);

        // First claim
        vm.prank(investor);
        fundraise.claim(pid, investor);

        // Second claim without new repayment → 0 additional
        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.claim(pid, investor);
        uint256 balAfter = usdc.balanceOf(investor);

        assertEq(balAfter, balBefore, "Should not get additional tokens on double claim");
    }

    // ═══════════════════════════════════════════════════════════════
    //                      ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════

    function test_createProject_nonManager_reverts() public {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 40_000e6,
            softCap: 20_000e6,
            totalInvested: 0,
            startAt: block.timestamp,
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + 7 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: PLATFORM_FEE,
                totalRepaid: 0,
                borrower: borrower,
                fundedTime: 0,
                loanToken: IERC20(address(usdc)),
                stage: Fundraise.Stage.ComingSoon
            })
        });

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.createProject(proj, 1);
    }

    function test_cancelProject_nonManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.cancelProject(pid);
    }

    function test_cancelProject_anyoneCanCancel_whenPreFundExpired() public {
        // Invest to reach softCap and trigger Open→PreFunded
        _investAs(investor, pid, 40_000e6, inviter);

        // Warp past preFundDuration
        vm.warp(block.timestamp + 8 days);

        // Anyone can cancel now
        vm.prank(attacker);
        fundraise.cancelProject(pid);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Canceled));
    }

    function test_claim_managerCanClaimOnBehalf() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(manager);
        fundraise.claim(pid, investor);
        uint256 balAfter = usdc.balanceOf(investor);

        assertGt(balAfter, balBefore, "Manager should be able to claim on behalf");
    }

    function test_claim_randomUserCannotClaimOnBehalf() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        vm.prank(attacker);
        vm.expectRevert(Fundraise.NotAManager.selector);
        fundraise.claim(pid, investor);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PLATFORM FEE CALCULATION
    // ═══════════════════════════════════════════════════════════════

    function test_transferFundsToBorrower_correctFeeDistribution() public {
        uint256 investAmount = 30_000e6;
        _investAs(investor, pid, investAmount, inviter);

        uint256 borrowerBefore = usdc.balanceOf(borrower);
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));

        _fundProject(pid);

        uint256 borrowerReceived = usdc.balanceOf(borrower) - borrowerBefore;
        uint256 treasuryReceived = usdc.balanceOf(address(treasury)) - treasuryBefore;

        uint256 expectedFee = (investAmount * PLATFORM_FEE) / BASIS_POINTS;
        assertEq(treasuryReceived, expectedFee, "Treasury should receive exact platform fee");
        assertEq(borrowerReceived, investAmount - expectedFee, "Borrower receives rest");
    }

    // ═══════════════════════════════════════════════════════════════
    //                   WITHDRAW INVESTMENT
    // ═══════════════════════════════════════════════════════════════

    function test_withdrawInvestment_afterCancel() public {
        _investAs(investor, pid, 10_000e6, inviter);

        vm.prank(manager);
        fundraise.cancelProject(pid);

        uint256 balBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        fundraise.withdrawInvestment(pid, investor);
        uint256 balAfter = usdc.balanceOf(investor);

        assertEq(balAfter - balBefore, 10_000e6, "Should get full investment back");
    }

    function test_withdrawInvestment_notCanceled_reverts() public {
        _investAs(investor, pid, 10_000e6, inviter);

        vm.prank(investor);
        vm.expectRevert(Fundraise.ProjectNotCanceled.selector);
        fundraise.withdrawInvestment(pid, investor);
    }

    // ═══════════════════════════════════════════════════════════════
    //                INVESTOR CLAIM ADDRESS REDIRECT
    // ═══════════════════════════════════════════════════════════════

    function test_claim_usesClaimAddress_whenSet() public {
        _investAs(investor, pid, 30_000e6, inviter);
        _fundProject(pid);
        _repayFull(pid);

        address altAddress = makeAddr("altClaim");

        vm.prank(owner);
        managerRegistry.setInvestorClaimAddress(investor, altAddress);

        vm.prank(investor);
        fundraise.claim(pid, investor);

        uint256 altBalance = usdc.balanceOf(altAddress);
        assertGt(altBalance, 0, "Claim should go to alt address");
    }

    // ═══════════════════════════════════════════════════════════════
    //                   SIGNATURE VERIFICATION
    // ═══════════════════════════════════════════════════════════════

    function test_invest_invalidSignature_reverts() public {
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.userNonces(investor);

        // Sign with wrong key
        (address wrongSigner, uint256 wrongPk) = makeAddrAndKey("wrong");
        bytes32 innerHash = keccak256(abi.encodePacked(investor, pid, uint256(5_000e6), currentNonce + 1, inviter));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, ethHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(investor);
        vm.expectRevert(Fundraise.NotTrustedSigner.selector);
        fundraise.investUpdateV2(pid, 5_000e6, currentNonce + 1, badSig, inviter);
    }

    function test_invest_borrowerCannotInvest() public {
        vm.prank(owner);
        usdc.mint(borrower, 5_000e6);
        vm.prank(borrower);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.userNonces(borrower);
        bytes memory sig = _signInvest(borrower, pid, 5_000e6, currentNonce + 1, inviter);

        vm.prank(borrower);
        vm.expectRevert(Fundraise.CannotInvestInOwnProject.selector);
        fundraise.investUpdateV2(pid, 5_000e6, currentNonce + 1, sig, inviter);
    }

    // ═══════════════════════════════════════════════════════════════
    //              PROJECT INITIALIZATION CHECKS (T-10)
    // ═══════════════════════════════════════════════════════════════

    function _buildValidProject() internal view returns (Fundraise.Project memory) {
        return Fundraise.Project({
            hardCap: 40_000e6,
            softCap: 20_000e6,
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
                loanToken: IERC20(address(usdc)),
                stage: Fundraise.Stage.ComingSoon
            })
        });
    }

    function test_createProject_revertsOnZeroSoftCap() public {
        Fundraise.Project memory proj = _buildValidProject();
        proj.softCap = 0;

        vm.prank(manager);
        vm.expectRevert(Fundraise.SoftCapMustBePositive.selector);
        fundraise.createProject(proj, 1);
    }

    function test_createProject_revertsOnSoftCapGtHardCap() public {
        Fundraise.Project memory proj = _buildValidProject();
        proj.softCap = 50_000e6;
        proj.hardCap = 40_000e6;

        vm.prank(manager);
        vm.expectRevert(Fundraise.SoftCapExceedsHardCap.selector);
        fundraise.createProject(proj, 1);
    }

    function test_createProject_revertsOnNonZeroTotalInvested() public {
        Fundraise.Project memory proj = _buildValidProject();
        proj.totalInvested = 1_000e6;

        vm.prank(manager);
        vm.expectRevert(Fundraise.TotalInvestedMustBeZero.selector);
        fundraise.createProject(proj, 1);
    }

    function test_createProject_revertsOnZeroBorrower() public {
        Fundraise.Project memory proj = _buildValidProject();
        proj.innerStruct.borrower = address(0);

        vm.prank(manager);
        vm.expectRevert(Fundraise.BorrowerMustBeSet.selector);
        fundraise.createProject(proj, 1);
    }

    function test_createProject_revertsOnZeroLoanToken() public {
        Fundraise.Project memory proj = _buildValidProject();
        proj.innerStruct.loanToken = IERC20(address(0));

        vm.prank(manager);
        vm.expectRevert(Fundraise.LoanTokenMustBeSet.selector);
        fundraise.createProject(proj, 1);
    }

    function test_createProject_validProject_succeeds() public {
        Fundraise.Project memory proj = _buildValidProject();

        vm.prank(manager);
        uint256 newPid = fundraise.createProject(proj, 1);

        (uint256 hardCap, uint256 softCap,,,,,,) = fundraise.projects(newPid);
        assertEq(hardCap, 40_000e6);
        assertEq(softCap, 20_000e6);
    }

    function test_invest_cannotSelfRefer() public {
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.userNonces(investor);
        // investor is also the inviter
        bytes memory sig = _signInvest(investor, pid, 5_000e6, currentNonce + 1, investor);

        vm.prank(investor);
        vm.expectRevert(Fundraise.InviterCannotBeInvestor.selector);
        fundraise.investUpdateV2(pid, 5_000e6, currentNonce + 1, sig, investor);
    }
}

/// @notice Mock LimitedSeller to verify addEarnedLimit callback
contract MockLimitedSeller_FR {
    struct Call {
        address user;
        uint256 investedAmount;
    }
    Call[] public calls;

    function addEarnedLimit(address user, uint256 investedAmount) external {
        calls.push(Call(user, investedAmount));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}

contract FundraiseLimitedSellerTest is Setup {
    MockLimitedSeller_FR public mockLimitedSeller;
    uint256 pid;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);

        mockLimitedSeller = new MockLimitedSeller_FR();

        vm.prank(owner);
        fundraise.setLimitedSeller(address(mockLimitedSeller));
    }

    function test_invest_callsAddEarnedLimit() public {
        _investAs(investor, pid, 5_000e6, inviter);

        assertEq(mockLimitedSeller.callCount(), 1);
        (address user, uint256 amount) = mockLimitedSeller.calls(0);
        assertEq(user, investor);
        assertEq(amount, 5_000e6);
    }

    function test_invest_multipleInvestments_multipleCallbacks() public {
        _investAs(investor, pid, 5_000e6, inviter);
        _investAs(investor, pid, 3_000e6, inviter);

        assertEq(mockLimitedSeller.callCount(), 2);
        (, uint256 amount1) = mockLimitedSeller.calls(0);
        (, uint256 amount2) = mockLimitedSeller.calls(1);
        assertEq(amount1, 5_000e6);
        assertEq(amount2, 3_000e6);
    }

    function test_invest_worksWithoutLimitedSeller() public {
        // Unset limitedSeller
        vm.prank(owner);
        fundraise.setLimitedSeller(address(0));

        // Should not revert
        _investAs(investor, pid, 5_000e6, inviter);

        (uint256 invested,) = fundraise.investorInfo(investor, pid);
        assertEq(invested, 5_000e6);
    }

    function test_setLimitedSeller_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        fundraise.setLimitedSeller(address(mockLimitedSeller));
    }

    function test_setLimitedSeller_emitsEvent() public {
        address newAddr = makeAddr("newLS");
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit Fundraise.LimitedSellerUpdated(newAddr);
        fundraise.setLimitedSeller(newAddr);
    }
}
