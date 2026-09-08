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
    //  SECTION 1: Fundraise — investUpdate (old) vs investUpdateV2 (new)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Build old-style signature (includes rootHash)
    function _signInvestOld(
        address _investor,
        uint256 _pid,
        uint256 _amount,
        bytes32 _rootHash,
        uint256 _nonce,
        address _inviter
    ) internal view returns (bytes memory sig) {
        bytes32 innerHash = keccak256(abi.encodePacked(_investor, _pid, _amount, _rootHash, _nonce, _inviter));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(backendPk, ethSignedHash);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Invest using old investUpdate (rootHash in signature, global nonce).
    function _investOldAs(address _investor, uint256 _pid, uint256 _amount, address _inviter) internal {
        vm.prank(owner);
        usdc.mint(_investor, _amount);

        vm.prank(_investor);
        usdc.approve(address(fundraise), _amount);

        uint256 currentGlobalNonce = fundraise.nonce();
        uint256 nonceForSig = currentGlobalNonce + 1;
        bytes32 rootHash = bytes32(0); // dummy rootHash
        bytes memory sig = _signInvestOld(_investor, _pid, _amount, rootHash, nonceForSig, _inviter);

        vm.prank(_investor);
        fundraise.investUpdate(_pid, _amount, rootHash, nonceForSig, sig, _inviter);
    }

    function test_investUpdate_old_works() public {
        uint256 amount = 5_000e6;
        uint256 globalNonceBefore = fundraise.nonce();
        uint256 userNonceBefore = fundraise.userNonces(investor);

        _investOldAs(investor, pid, amount, inviter);

        // Verify investment recorded
        (uint256 invested,) = fundraise.investorInfo(investor, pid);
        assertEq(invested, amount, "Old investUpdate: investment not recorded");

        // Old investUpdate still uses the legacy global nonce.
        assertEq(fundraise.nonce(), globalNonceBefore + 1, "Old investUpdate: global nonce not incremented");
        assertEq(fundraise.userNonces(investor), userNonceBefore, "Old investUpdate: user nonce should stay unchanged");
    }

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

    function test_old_and_new_invest_do_not_conflict() public {
        // First: invest via old method (rootHash signature)
        _investOldAs(investor, pid, 3_000e6, inviter);

        // Second: invest via new method (no rootHash) — same investor
        _investAs(investor, pid, 2_000e6, address(0));

        // Third: different investor uses old method
        _investOldAs(investor2, pid, 4_000e6, inviter);

        // Fourth: different investor uses new method
        _investAs(investor2, pid, 1_000e6, address(0));

        // Verify both accumulated correctly
        (uint256 inv1,) = fundraise.investorInfo(investor, pid);
        assertEq(inv1, 5_000e6, "Investor1 total should be 3000+2000");

        (uint256 inv2,) = fundraise.investorInfo(investor2, pid);
        assertEq(inv2, 5_000e6, "Investor2 total should be 4000+1000");

        // Old invests use the legacy global nonce; new invests use per-user nonce.
        assertEq(fundraise.nonce(), 2, "Global nonce should count the two old invests");
        assertEq(fundraise.userNonces(investor), 1, "Investor1 user nonce should count only the new invest");
        assertEq(fundraise.userNonces(investor2), 1, "Investor2 user nonce should count only the new invest");
    }

    function test_old_investUpdate_wrong_nonce_reverts() public {
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 wrongNonce = fundraise.userNonces(investor) + 2; // skip one
        bytes32 rootHash = bytes32(0);
        bytes memory sig = _signInvestOld(investor, pid, 5_000e6, rootHash, wrongNonce, inviter);

        vm.prank(investor);
        vm.expectRevert(Fundraise.IncorrectNonce.selector);
        fundraise.investUpdate(pid, 5_000e6, rootHash, wrongNonce, sig, inviter);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 2: Fundraise — createProject overloads
    // ═══════════════════════════════════════════════════════════════════

    function test_createProject_old_with_whitelistRoot() public {
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

        bytes32 fakeRoot = bytes32(uint256(0xdead));
        vm.prank(manager);
        uint256 newPid = fundraise.createProject(proj, fakeRoot, 42);

        // Verify project was created
        (uint256 hardCap,,,,,,, ) = fundraise.projects(newPid);
        assertEq(hardCap, 20_000e6, "Old createProject: hardCap mismatch");
    }

    function test_createProject_new_without_whitelistRoot() public {
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
        uint256 newPid = fundraise.createProject(proj, 99);

        (uint256 hardCap,,,,,,, ) = fundraise.projects(newPid);
        assertEq(hardCap, 30_000e6, "New createProject: hardCap mismatch");
    }

    function test_createProject_both_overloads_sequential() public {
        uint256 countBefore = fundraise.projectCount();

        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: 10_000e6,
            softCap: 5_000e6,
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

        vm.startPrank(manager);
        uint256 pid1 = fundraise.createProject(proj, bytes32(uint256(1)), 100); // old
        uint256 pid2 = fundraise.createProject(proj, 200); // new
        vm.stopPrank();

        assertEq(pid1, countBefore, "Old overload: wrong pid");
        assertEq(pid2, countBefore + 1, "New overload: wrong pid");
        assertEq(fundraise.projectCount(), countBefore + 2, "Project count should increase by 2");
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
    //  SECTION 4: Fundraise — deprecated whitelistRoots
    // ═══════════════════════════════════════════════════════════════════

    function test_whitelistRoots_returns_zero() public view {
        bytes32 root = fundraise.whitelistRoots(pid);
        assertEq(root, bytes32(0), "whitelistRoots should return 0 for new projects");
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

        // Verify rewards recorded
        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertGt(totalTokens, 0, "Old recordInvestment: no token rewards");
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
        assertGt(totalTokens, 0, "New recordInvestment: no token rewards");
        (uint256 inviterUSDC,,,,) = rewardSystem.getProjectRewards(inviter, pid);
        assertGt(inviterUSDC, 0, "New recordInvestment: no inviter USDC reward");
    }

    function test_rewardSystem_old_and_new_recordInvestment_accumulate() public {
        // First investment via new V2 flow (5-param recordInvestment)
        _investAs(investor, pid, 5_000e6, inviter);
        (, uint256 tokensAfterFirst,,,) = rewardSystem.getProjectRewards(investor, pid);

        // Second investment via old flow — simulate by calling 4-param directly
        vm.prank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(this), address(treasury));
        rewardSystem.recordInvestment(investor, 5_000e6, address(0), pid);
        vm.prank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(fundraise), address(treasury));

        (, uint256 tokensAfterSecond,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertGt(tokensAfterSecond, tokensAfterFirst, "Rewards should accumulate across old and new calls");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 6: RewardSystem — activateProjectRewards overloads
    // ═══════════════════════════════════════════════════════════════════

    function test_activateProjectRewards_old_2params() public {
        _investAs(investor, pid, 10_000e6, inviter);

        // Old method (2 params, no maxUSD)
        vm.prank(manager);
        fundraise.transferFundsToBorrower(pid);

        uint256 startTime = rewardSystem.projectVestingStartTime(pid);
        assertGt(startTime, 0, "Old activateProjectRewards: vesting not started");
    }

    function test_activateProjectRewards_new_3params() public {
        uint256 newPid = _createProject(10_000e6, 50_000e6);
        _investAs(investor, newPid, 10_000e6, inviter);

        // New method (3 params, with maxUSD) — must cover buy-back cost
        vm.prank(manager);
        fundraise.transferFundsToBorrower(newPid, 10_000e6);

        uint256 startTime = rewardSystem.projectVestingStartTime(newPid);
        assertGt(startTime, 0, "New activateProjectRewards: vesting not started");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  SECTION 7: RewardSystem — Oracle fallback to Uniswap V2
    // ═══════════════════════════════════════════════════════════════════

    function test_oracle_fallback_to_uniswap() public {
        // Deploy a fresh RewardSystem WITHOUT oracle
        vm.startPrank(owner);
        RewardSystem rsNoOracle;
        {
            RewardSystem impl = new RewardSystem();
            bytes memory initData = abi.encodeCall(
                RewardSystem.initialize,
                (address(managerRegistry), address(token), address(usdc), address(mockRouter))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            rsNoOracle = RewardSystem(address(proxy));
        }

        // Seed it with USDC for rewards
        usdc.mint(address(rsNoOracle), 100_000e6);

        // Point system to new RS
        managerRegistry.setContractAddresses(address(rsNoOracle), address(fundraise), address(treasury));
        fundraise.setRewardSystem(address(rsNoOracle));
        vm.stopPrank();

        // oracle is address(0) → should use Uniswap V2 fallback
        assertEq(rsNoOracle.oracle(), address(0), "Oracle should not be set");

        // Invest — should use Uniswap spot price
        uint256 fallbackPid = _createProject(5_000e6, 50_000e6);
        _investAs(investor, fallbackPid, 5_000e6, inviter);

        // tokenPercentage = 6% → 300 USDC worth
        // MockRouter: 1 USDC = 100 tokens → 300 * 100 = 30,000 tokens
        (, uint256 totalTokens,,,) = rsNoOracle.getProjectRewards(investor, fallbackPid);
        assertEq(totalTokens, 30_000e18, "Uniswap fallback: wrong token amount");

        // Restore original RS
        vm.startPrank(owner);
        managerRegistry.setContractAddresses(address(rewardSystem), address(fundraise), address(treasury));
        fundraise.setRewardSystem(address(rewardSystem));
        vm.stopPrank();
    }

    function test_oracle_set_uses_oracle_not_uniswap() public {
        // Default setup already has oracle → verify oracle path gives different result
        _investAs(investor, pid, 10_000e6, inviter);

        // Oracle price: 1 token = 0.01 USD (1e6 in 8 decimals)
        // tokenPercentage = 6% → 600 USDC worth
        // tokensAmount = 600e6 * 1e8 * 1e18 / (1e6 * 1e6) = 60_000e18
        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, 60_000e18, "Oracle path: wrong token amount");
    }

    function test_oracle_fallback_reverts_when_uniswap_has_no_liquidity() public {
        // Deploy fresh RS without oracle
        vm.startPrank(owner);
        RewardSystem rsNoOracle;
        {
            RewardSystem impl = new RewardSystem();
            bytes memory initData = abi.encodeCall(
                RewardSystem.initialize,
                (address(managerRegistry), address(token), address(usdc), address(mockRouter))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            rsNoOracle = RewardSystem(address(proxy));
        }
        usdc.mint(address(rsNoOracle), 100_000e6);
        managerRegistry.setContractAddresses(address(rsNoOracle), address(fundraise), address(treasury));
        fundraise.setRewardSystem(address(rsNoOracle));

        // Make Uniswap router revert
        mockRouter.setShouldRevert(true);
        vm.stopPrank();

        uint256 fallbackPid = _createProject(5_000e6, 50_000e6);

        // Prepare invest manually for expectRevert
        vm.prank(owner);
        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 5_000e6);

        uint256 currentNonce = fundraise.userNonces(investor);
        bytes memory sig = _signInvest(investor, fallbackPid, 5_000e6, currentNonce + 1, inviter);

        vm.prank(investor);
        vm.expectRevert("Uniswap pool does not exist or has no liquidity");
        fundraise.investUpdateV2(fallbackPid, 5_000e6, currentNonce + 1, sig, inviter);

        // Restore
        vm.startPrank(owner);
        mockRouter.setShouldRevert(false);
        managerRegistry.setContractAddresses(address(rewardSystem), address(fundraise), address(treasury));
        fundraise.setRewardSystem(address(rewardSystem));
        vm.stopPrank();
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
        assertEq(result.availableBuyTokensInUSDC, 600e6, "Legacy fallback: wrong available limit");
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
        assertEq(result.availableBuyTokensInUSDC, 600e6, "Post-migration: should use earnedLimitUsdc");
    }

    function test_limitedSeller_migrateEarnedLimits_onlyOwner() public {
        address[] memory users = new address[](1);
        users[0] = investor;
        uint256[] memory limits = new uint256[](1);
        limits[0] = 100e6;

        vm.prank(attacker);
        vm.expectRevert();
        limitedSeller.migrateEarnedLimits(users, limits);
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
    //  SECTION 9: End-to-end — full lifecycle with both old and new paths
    // ═══════════════════════════════════════════════════════════════════

    function test_e2e_mixed_old_new_full_lifecycle() public {
        // 1. Create project via old method (with whitelistRoot)
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
        uint256 e2ePid = fundraise.createProject(proj, bytes32(0), 777);

        // 2. Investor1 invests via OLD investUpdate
        _investOldAs(investor, e2ePid, 6_000e6, inviter);

        // 3. Investor2 invests via NEW investUpdateV2
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

        // 7. Verify rewards for both investors (both got rewards via RewardSystem)
        (, uint256 tokens1,,,) = rewardSystem.getProjectRewards(investor, e2ePid);
        (, uint256 tokens2,,,) = rewardSystem.getProjectRewards(investor2, e2ePid);
        assertGt(tokens1, 0, "Investor1 should have token rewards");
        assertGt(tokens2, 0, "Investor2 should have token rewards");

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
