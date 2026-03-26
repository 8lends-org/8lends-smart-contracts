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

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("test-root-2"));
        bytes memory sig = _signInvest(investor2, pid, 1_000e6, rootHash, currentNonce + 1, address(0));

        // This invest call will trigger the Canceled transition and return silently
        vm.prank(investor2);
        fundraise.investUpdate(pid, 1_000e6, rootHash, currentNonce + 1, sig, address(0));

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
    //    T-09: MERKLE ROOT AND NONCE UNCHANGED ON FAILED INVEST
    // ═══════════════════════════════════════════════════════════════

    function test_merkleRootUnchanged_comingSoonBeforeStart() public {
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
        uint256 futurePid = fundraise.createProject(proj, bytes32(0), 2);

        uint256 nonceBefore = fundraise.nonce();
        bytes32 rootBefore = fundraise.whitelistRoots(futurePid);

        // Prepare invest
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 nonceForSig = nonceBefore + 1;
        bytes32 rootHash = keccak256(abi.encodePacked("new-root"));
        bytes memory sig = _signInvest(investor, futurePid, 5_000e6, rootHash, nonceForSig, inviter);

        vm.prank(investor);
        fundraise.investUpdate(futurePid, 5_000e6, rootHash, nonceForSig, sig, inviter);

        // FIX: nonce must NOT be incremented when _invest returns early
        assertEq(fundraise.nonce(), nonceBefore, "Nonce must not change on failed invest");

        // FIX: merkle root must NOT be updated when _invest returns early
        assertEq(fundraise.whitelistRoots(futurePid), rootBefore, "Merkle root must not change on failed invest");

        // No tokens were transferred from investor
        (,, uint256 totalInvested,,,,,) = fundraise.projects(futurePid);
        assertEq(totalInvested, 0, "No actual investment happened");
    }

    function test_merkleRootUpdated_onSuccessfulInvest() public {
        bytes32 rootBefore = fundraise.whitelistRoots(pid);
        uint256 nonceBefore = fundraise.nonce();

        // Prepare invest
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 nonceForSig = nonceBefore + 1;
        bytes32 rootHash = keccak256(abi.encodePacked("new-root"));
        bytes memory sig = _signInvest(investor, pid, 5_000e6, rootHash, nonceForSig, inviter);

        vm.prank(investor);
        fundraise.investUpdate(pid, 5_000e6, rootHash, nonceForSig, sig, inviter);

        // Root must be updated on successful invest
        assertEq(fundraise.whitelistRoots(pid), rootHash, "Merkle root must be updated on successful invest");

        // Nonce must be incremented on successful invest
        assertEq(fundraise.nonce(), nonceBefore + 1, "Nonce must be incremented on successful invest");

        // Investment actually happened
        (,, uint256 totalInvested,,,,,) = fundraise.projects(pid);
        assertEq(totalInvested, 5_000e6, "Investment should be recorded");
    }

    // ═══════════════════════════════════════════════════════════════
    //           VULNERABILITY #2: GLOBAL NONCE BOTTLENECK
    // ═══════════════════════════════════════════════════════════════

    function test_vuln2_globalNonce_secondInvestorFails() public {
        uint256 currentNonce = fundraise.nonce();
        uint256 nonceForSig = currentNonce + 1;
        bytes32 rootHash = keccak256(abi.encodePacked("root1"));

        // Investor 1 prepares and sends
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);
        bytes memory sig1 = _signInvest(investor, pid, 5_000e6, rootHash, nonceForSig, inviter);

        // Investor 2 prepares with SAME nonce (signed at the same time)
        vm.prank(owner);
        usdc.mint(investor2, 3_000e6);
        vm.prank(investor2);
        usdc.approve(address(fundraise), 3_000e6);
        bytes memory sig2 = _signInvest(investor2, pid, 3_000e6, rootHash, nonceForSig, inviter);

        // Investor 1 succeeds
        vm.prank(investor);
        fundraise.investUpdate(pid, 5_000e6, rootHash, nonceForSig, sig1, inviter);

        // Investor 2 FAILS because nonce already used
        vm.prank(investor2);
        vm.expectRevert("Incorrect nonce");
        fundraise.investUpdate(pid, 3_000e6, rootHash, nonceForSig, sig2, inviter);
    }

    // ═══════════════════════════════════════════════════════════════
    //       VULNERABILITY #4: MERKLE PROOF NEVER VERIFIED
    // ═══════════════════════════════════════════════════════════════

    function test_vuln4_merkleWhitelistNotEnforced() public {
        // Set a whitelist root
        vm.prank(manager);
        fundraise.setWhitelist(keccak256("real-merkle-root"), pid);

        // Invest from an address that is definitely NOT in the whitelist
        // This should fail if whitelist was checked, but it succeeds
        _investAs(attacker, pid, 5_000e6, address(0));

        // Attacker's investment was accepted
        (uint256 investedAmount,) = fundraise.investorInfo(attacker, pid);
        assertEq(investedAmount, 5_000e6, "Attacker invested despite whitelist");
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
        vm.expectRevert("Not a manager");
        fundraise.createProject(proj, bytes32(0), 1);
    }

    function test_cancelProject_nonManager_reverts() public {
        vm.prank(attacker);
        vm.expectRevert("Not a manager");
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
        vm.expectRevert("Not a manager");
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
        vm.expectRevert("Project not canceled");
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

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("test"));

        // Sign with wrong key
        (address wrongSigner, uint256 wrongPk) = makeAddrAndKey("wrong");
        bytes32 innerHash = keccak256(abi.encodePacked(investor, pid, uint256(5_000e6), rootHash, currentNonce + 1, inviter));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, ethHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(investor);
        vm.expectRevert("Not a trusted signer");
        fundraise.investUpdate(pid, 5_000e6, rootHash, currentNonce + 1, badSig, inviter);
    }

    function test_invest_borrowerCannotInvest() public {
        vm.prank(owner);
        usdc.mint(borrower, 5_000e6);
        vm.prank(borrower);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("test"));
        bytes memory sig = _signInvest(borrower, pid, 5_000e6, rootHash, currentNonce + 1, inviter);

        vm.prank(borrower);
        vm.expectRevert("Cannot invest in your own project");
        fundraise.investUpdate(pid, 5_000e6, rootHash, currentNonce + 1, sig, inviter);
    }

    function test_invest_cannotSelfRefer() public {
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.nonce();
        bytes32 rootHash = keccak256(abi.encodePacked("test"));
        // investor is also the inviter
        bytes memory sig = _signInvest(investor, pid, 5_000e6, rootHash, currentNonce + 1, investor);

        vm.prank(investor);
        vm.expectRevert("Inviter cannot be the same as the investor");
        fundraise.investUpdate(pid, 5_000e6, rootHash, currentNonce + 1, sig, investor);
    }
}
