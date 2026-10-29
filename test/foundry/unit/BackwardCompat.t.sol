// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {LimitedSeller} from "../../../contracts/core/LimitedSeller.sol";
import {MockOracle} from "../../../contracts/mocks/MockOracle.sol";

/// @title Backward-Compatibility Tests
/// @notice Verifies that old functions (current front/back) continue to work
///         after upgrade, new V2 functions work correctly, and both don't conflict.
contract BackwardCompatTest is Setup {
    LimitedSeller public limitedSeller;

    uint256 pid; // default project

    function setUp() public override {
        super.setUp();

        // ── Deploy LimitedSeller (UUPS proxy) ──
        vm.startPrank(owner);
        {
            LimitedSeller impl = new LimitedSeller();
            bytes memory initData = abi.encodeCall(
                LimitedSeller.initialize,
                (address(fundraise), address(mockRouter), address(usdc), address(token), 60_000, address(managerRegistry))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            limitedSeller = LimitedSeller(address(proxy));
        }

        // Connect LimitedSeller to Fundraise
        fundraise.setLimitedSeller(address(limitedSeller));

        // Register limitedSeller as pool so token transfers work
        managerRegistry.setPoolStatus(address(limitedSeller), true);
        vm.stopPrank();

        // Create a default project
        pid = _createProject(10_000e6, 50_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 1: Fundraise — investUpdateV2
    // ═══════════════════════════════════════════════════════════════════

    function test_investUpdateV2_new_works() public {
        uint256 amount = 5_000e6;
        uint256 userNonceBefore = fundraise.userNonces(investor);

        _investAs(investor, pid, amount, inviter);

        // Verify investment recorded
        (uint256 invested,) = fundraise.investorInfo(investor, pid);
        assertEq(invested, amount, "V2 investUpdate: investment not recorded");

        // Verify per-user nonce incremented
        assertEq(fundraise.userNonces(investor), userNonceBefore + 1, "V2 investUpdate: user nonce not incremented");
    }

    function test_investUpdateV2_wrong_nonce_reverts() public {
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 wrongNonce = fundraise.userNonces(investor) + 2; // skip one
        bytes memory sig = _signInvest(investor, pid, 5_000e6, wrongNonce, inviter);

        vm.prank(investor);
        vm.expectRevert(Fundraise.IncorrectNonce.selector);
        fundraise.investUpdateV2(pid, 5_000e6, wrongNonce, sig, inviter);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 2: Fundraise — createProject
    // ═══════════════════════════════════════════════════════════════════

    function test_createProject_takesOnlyTheHash() public {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 30_000e6,
            softCap: 15_000e6,
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

        vm.prank(manager);
        uint256 newPid = fundraise.createProject(proj, _nextProjectHash());

        (uint256 hardCap,,,,,,, ) = fundraise.projects(newPid);
        assertEq(hardCap, 30_000e6, "New createProject: hardCap mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 3: Fundraise — transferFundsToBorrower overloads
    // ═══════════════════════════════════════════════════════════════════

    function test_transferFundsToBorrower_old_no_maxUSD() public {
        // Fill the project to softCap
        _investAs(investor, pid, 10_000e6, inviter);

        // Old method (no maxUSD param)
        vm.prank(manager);
        fundraise.transferFundsToBorrower(pid);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(pid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Funded), "Old transferFunds: not Funded");
    }

    function test_transferFundsToBorrower_new_with_maxUSD() public {
        uint256 newPid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, newPid, 10_000e6, inviter);

        // New method (with maxUSD param)
        vm.prank(manager);
        fundraise.transferFundsToBorrower(newPid, 1_000e6);

        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(newPid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Funded), "New transferFunds: not Funded");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 5: RewardSystem — recordInvestment overloads
    // ═══════════════════════════════════════════════════════════════════

    function test_rewardSystem_old_recordInvestment_4params() public {
        // Old method is called internally when old Fundraise calls recordInvestment(user, amount, inviter, pid)
        // We simulate this by temporarily making address(this) the fundraise
        vm.prank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(this), address(treasury));

        // Call old 4-param overload (assumes USDC)
        rewardSystem.recordInvestment(investor, 10_000e6, inviter, pid);

        // Token cashback is off; the referral half is what both overloads still do
        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, 0, "Old recordInvestment: token rewards must not accrue");
        // Inviter should have USDC reward
        (uint256 inviterUSDC,,,,) = rewardSystem.getProjectRewards(inviter, pid);
        assertGt(inviterUSDC, 0, "Old recordInvestment: no inviter USDC reward");

        // Restore
        vm.prank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(fundraise), address(treasury));
    }

    function test_rewardSystem_new_recordInvestment_5params() public {
        // New method with loanToken parameter — called via normal invest flow
        _investAs(investor, pid, 10_000e6, inviter);

        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, 0, "New recordInvestment: token rewards must not accrue");
        (uint256 inviterUSDC,,,,) = rewardSystem.getProjectRewards(inviter, pid);
        assertGt(inviterUSDC, 0, "New recordInvestment: no inviter USDC reward");
    }

    function test_rewardSystem_old_and_new_recordInvestment_accumulate() public {
        // First investment via new V2 flow (5-param recordInvestment)
        _investAs(investor, pid, 5_000e6, inviter);
        (uint256 inviterAfterFirst,,,,) = rewardSystem.getProjectRewards(inviter, pid);

        // Second investment via old flow — simulate by calling 4-param directly
        vm.prank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(this), address(treasury));
        rewardSystem.recordInvestment(investor, 5_000e6, inviter, pid);
        vm.prank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(fundraise), address(treasury));

        (uint256 inviterAfterSecond,,,,) = rewardSystem.getProjectRewards(inviter, pid);
        assertGt(inviterAfterSecond, inviterAfterFirst, "Referral USDC should accumulate across old and new calls");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 6: rewards start on either arm of transferFundsToBorrower
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Both this and the next reach activateProjectRewards(pid, total, maxUSD) — Fundraise
    ///      has no other call. What differs is the transferFundsToBorrower arm they come through.
    function test_rewardsStart_whenTheTransferNamesNoMaxUSD() public {
        _investAs(investor, pid, 10_000e6, inviter);

        vm.prank(manager);
        fundraise.transferFundsToBorrower(pid);

        uint256 startTime = rewardSystem.projectVestingStartTime(pid);
        assertGt(startTime, 0, "vesting did not start");
    }

    function test_rewardsStart_whenTheTransferNamesAMaxUSD() public {
        uint256 newPid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, newPid, 10_000e6, inviter);

        // The maxUSD has to cover the buy-back cost
        vm.prank(manager);
        fundraise.transferFundsToBorrower(newPid, 10_000e6);

        uint256 startTime = rewardSystem.projectVestingStartTime(newPid);
        assertGt(startTime, 0, "vesting did not start");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 8: LimitedSeller — earnedLimits migration
    // ═══════════════════════════════════════════════════════════════════

    function test_limitedSeller_legacy_fallback_when_earnedLimit_zero() public {
        // Invest and fund project so investor has funded investments
        _investAs(investor, pid, 10_000e6, inviter);
        _fundProject(pid);

        // earnedLimitUsdc should be > 0 because addEarnedLimit was called during invest
        // But let's test a user who invested before upgrade (no earnedLimitUsdc)
        // We simulate by using investor2 who has funded investment but no earnedLimit

        // Transfer investment to investor2 via market mock (or just check directly)
        // Actually, investor already has earnedLimitUsdc from addEarnedLimit.
        // Let's create a scenario: investor2 has investorInfo but no earnedLimitUsdc

        // We need to invest as investor2 via old method that doesn't call addEarnedLimit
        // The old investUpdate still calls _invest which calls addEarnedLimit if limitedSeller is set.
        // So we need to test the scenario where limitedSeller was deployed AFTER investments.

        // Scenario: disconnect limitedSeller, invest, reconnect
        vm.prank(owner);
        fundraise.setLimitedSeller(address(0)); // disconnect

        uint256 pid2 = _createProject(10_000e6, 50_000e6);
        _investAs(investor2, pid2, 10_000e6, inviter);
        _fundProject(pid2);

        vm.prank(owner);
        fundraise.setLimitedSeller(address(limitedSeller)); // reconnect

        // investor2 has funded investment but earnedLimitUsdc == 0 (pre-upgrade user)
        assertEq(limitedSeller.earnedLimitUsdc(investor2), 0, "Pre-upgrade user should have 0 earnedLimit");

        // estimateAvailableBuy should fall back to legacy calculation
        uint256[] memory pids = new uint256[](1);
        pids[0] = pid2;
        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor2, pids);

        // Legacy: fundedProjectsInvestedTotal * percent / BASIS_POINTS
        // = 10_000e6 * 60_000 / 1_000_000 = 600e6
        assertEq(result.fundedProjectsInvestedTotal, 10_000e6, "Legacy: wrong total invested");
        assertEq(result.availableBuyTokensInUSDC, 0, "purchases are closed");
    }

    function test_limitedSeller_migrateEarnedLimits() public {
        // Simulate pre-upgrade users with no earnedLimitUsdc
        vm.prank(owner);
        fundraise.setLimitedSeller(address(0));

        uint256 pid2 = _createProject(10_000e6, 50_000e6);
        _investAs(investor, pid2, 10_000e6, inviter);
        _investAs(investor2, pid2, 8_000e6, address(0));
        _fundProject(pid2);

        vm.prank(owner);
        fundraise.setLimitedSeller(address(limitedSeller));

        // Both users have 0 earnedLimit
        assertEq(limitedSeller.earnedLimitUsdc(investor), 0);
        assertEq(limitedSeller.earnedLimitUsdc(investor2), 0);

        // Owner migrates earned limits (calculated off-chain from historical data)
        address[] memory users = new address[](2);
        users[0] = investor;
        users[1] = investor2;
        uint256[] memory limits = new uint256[](2);
        limits[0] = 600e6;  // 10_000 * 6%
        limits[1] = 480e6;  // 8_000 * 6%

        vm.prank(owner);
        limitedSeller.migrateEarnedLimits(users, limits);

        // Verify migrated values
        assertEq(limitedSeller.earnedLimitUsdc(investor), 600e6, "Migration: investor limit wrong");
        assertEq(limitedSeller.earnedLimitUsdc(investor2), 480e6, "Migration: investor2 limit wrong");

        // After migration, estimateAvailableBuy uses earnedLimitUsdc (not legacy calc)
        uint256[] memory pids = new uint256[](1);
        pids[0] = pid2;
        LimitedSeller.EstimateResult memory result = limitedSeller.estimateAvailableBuy(investor, pids);
        assertEq(result.availableBuyTokensInUSDC, 0, "purchases are closed");
    }


    function test_limitedSeller_addEarnedLimit_on_new_investment() public {
        // Invest — should automatically accrue earnedLimit via addEarnedLimit
        _investAs(investor, pid, 10_000e6, inviter);

        // earnedLimit = investedAmount * percent / BASIS_POINTS = 10_000e6 * 60_000 / 1_000_000 = 600e6
        assertEq(limitedSeller.earnedLimitUsdc(investor), 600e6, "addEarnedLimit: wrong accrued limit");

        // Second investment adds more
        _investAs(investor, pid, 5_000e6, address(0));
        // += 5_000e6 * 60_000 / 1_000_000 = 300e6 → total 900e6
        assertEq(limitedSeller.earnedLimitUsdc(investor), 900e6, "addEarnedLimit: second invest wrong");
    }

    function test_limitedSeller_migration_then_new_invest_accumulates() public {
        // Pre-upgrade user with migrated limit
        vm.prank(owner);
        fundraise.setLimitedSeller(address(0));

        uint256 pid2 = _createProject(10_000e6, 50_000e6);
        _investAs(investor, pid2, 10_000e6, inviter);

        vm.prank(owner);
        fundraise.setLimitedSeller(address(limitedSeller));

        // Migrate historical limit
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory limits = new uint256[](1);
        limits[0] = 600e6;
        vm.prank(owner);
        limitedSeller.migrateEarnedLimits(users, limits);

        assertEq(limitedSeller.earnedLimitUsdc(investor), 600e6);

        // New investment accrues on top of migrated limit
        _investAs(investor, pid2, 5_000e6, address(0));
        // += 5_000e6 * 60_000 / 1_000_000 = 300e6 → total 900e6
        assertEq(limitedSeller.earnedLimitUsdc(investor), 900e6, "Migration + new invest: wrong total");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 9: End-to-end — full lifecycle
    // ═══════════════════════════════════════════════════════════════════

    function test_e2e_full_lifecycle() public {
        // 1. Create project
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 20_000e6,
            softCap: 10_000e6,
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
        vm.prank(manager);
        uint256 e2ePid = fundraise.createProject(proj, _nextProjectHash());

        // 2. Investor1 invests
        _investAs(investor, e2ePid, 6_000e6, inviter);

        // 3. Investor2 invests
        _investAs(investor2, e2ePid, 6_000e6, inviter);

        // 4. Verify both investments recorded
        (uint256 inv1,) = fundraise.investorInfo(investor, e2ePid);
        (uint256 inv2,) = fundraise.investorInfo(investor2, e2ePid);
        assertEq(inv1, 6_000e6);
        assertEq(inv2, 6_000e6);

        // 5. Transfer funds to borrower via new method (with maxUSD)
        vm.prank(manager);
        fundraise.transferFundsToBorrower(e2ePid, 1_000e6);

        // 6. Verify project is Funded and vesting started
        (,,,,,,, Fundraise.InnerProjectStruct memory inner) = fundraise.projects(e2ePid);
        assertEq(uint8(inner.stage), uint8(Fundraise.Stage.Funded));
        assertGt(rewardSystem.projectVestingStartTime(e2ePid), 0, "Vesting should start");

        // 7. Both paths record the inviter the same way; neither accrues token cashback
        (uint256 inviterUSDC, uint256 tokens1,,,) = rewardSystem.getProjectRewards(inviter, e2ePid);
        (, uint256 tokens2,,,) = rewardSystem.getProjectRewards(investor2, e2ePid);
        assertGt(inviterUSDC, 0, "Inviter should have USDC from both investments");
        assertEq(tokens1, 0, "Token cashback is off");
        assertEq(tokens2, 0, "Token cashback is off");

        // 8. Repay and claim
        _repayFull(e2ePid);

        vm.prank(investor);
        fundraise.claim(e2ePid, investor);
        vm.prank(investor2);
        fundraise.claim(e2ePid, investor2);

        // 9. Verify claims
        (, uint256 claimed1) = fundraise.investorInfo(investor, e2ePid);
        (, uint256 claimed2) = fundraise.investorInfo(investor2, e2ePid);
        assertGt(claimed1, 0, "Investor1 should have claimed");
        assertGt(claimed2, 0, "Investor2 should have claimed");
        // Both invested same amount → same claim
        assertEq(claimed1, claimed2, "Equal investors should claim equally");
    }
}
