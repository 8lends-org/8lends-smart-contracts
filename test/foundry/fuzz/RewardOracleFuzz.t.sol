// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {MockOracle} from "../../../contracts/mocks/MockOracle.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Mock ERC20 with configurable decimals for fuzz testing
contract FuzzMockERC20 is ERC20 {
    uint8 private _dec;

    constructor(uint8 dec_) ERC20("FuzzToken", "FUZZ") {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Fuzz tests for Oracle price calculation in RewardSystem.recordInvestment
contract RewardOracleFuzzTest is Setup {
    uint256 constant BP = 1_000_000;
    uint256 constant TOKEN_PERCENTAGE = 60_000; // 6%
    uint256 constant PRICE_DECIMALS = 8;

    // ═══════════════════════════════════════════════════════════════
    //     T-01 Fuzz: random prices/amounts → tokensAmount consistent
    // ═══════════════════════════════════════════════════════════════

    /// @notice tokensAmount is always > 0 and consistent with oracle price
    function testFuzz_recordInvestment_oraclePriceConsistency(
        uint256 amount,
        uint256 price
    ) public {
        // Bound inputs to realistic ranges
        // amount: 100 USDC to 10M USDC (6 decimals)
        amount = bound(amount, 100e6, 10_000_000e6);
        // price: 0.0001 USD to 100K USD per token (8 decimals)
        // Lower bound ensures tokensAmount > 0 after mulDiv rounding
        price = bound(price, 1e4, 1e13);

        // Set oracle price for the reward token
        vm.prank(owner);
        mockOracle.setPrice(address(token), price);

        // Create a fresh project for each fuzz run
        uint256 pid = _createProject(amount / 2 + 1, amount + 1);

        // Invest
        _investAs(investor, pid, amount, inviter);

        // Verify token rewards
        (, uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);

        // Expected: usdcRewardAmount = amount * 6% / 1e6
        uint256 usdcRewardAmount = (amount * TOKEN_PERCENTAGE) / BP;

        // Replicate the two-step mulDiv from the contract
        uint256 tokenDecimals = 18; // Token has 18 decimals
        uint256 usdcDecimals = 6;   // USDC has 6 decimals
        uint256 expectedTokens = Math.mulDiv(
            Math.mulDiv(usdcRewardAmount, 10 ** PRICE_DECIMALS, price),
            10 ** tokenDecimals,
            10 ** usdcDecimals
        );

        assertEq(totalTokens, expectedTokens, "Token reward mismatch");
        assertGt(totalTokens, 0, "Token reward must be > 0");
    }

    /// @notice Higher price → fewer tokens (inverse relationship)
    function testFuzz_recordInvestment_higherPriceFewerTokens(
        uint256 amount,
        uint256 priceLow,
        uint256 priceHigh
    ) public {
        amount = bound(amount, 100e6, 1_000_000e6);
        priceLow = bound(priceLow, 1e4, 1e12);
        priceHigh = bound(priceHigh, priceLow + 1, 1e14);

        // First investment with low price
        vm.prank(owner);
        mockOracle.setPrice(address(token), priceLow);
        uint256 pid1 = _createProject(amount / 2 + 1, amount + 1);
        _investAs(investor, pid1, amount, inviter);
        (, uint256 tokensLowPrice,,,) = rewardSystem.getProjectRewards(investor, pid1);

        // Second investment with high price (different investor to avoid isNewUser conflict)
        vm.prank(owner);
        mockOracle.setPrice(address(token), priceHigh);
        uint256 pid2 = _createProject(amount / 2 + 1, amount + 1);
        _investAs(investor2, pid2, amount, inviter);
        (, uint256 tokensHighPrice,,,) = rewardSystem.getProjectRewards(investor2, pid2);

        assertGe(tokensLowPrice, tokensHighPrice, "Lower price must yield >= tokens");
    }

    /// @notice Bonus threshold works correctly with different loanToken decimals
    function testFuzz_convertToUSD_differentDecimals(
        uint8 loanDecimals,
        uint256 loanPrice,
        uint256 amount
    ) public {
        // Bound decimals to realistic range (6-18)
        loanDecimals = uint8(bound(loanDecimals, 6, 18));
        // Price: $0.01 to $10000 per token
        loanPrice = bound(loanPrice, 1e6, 1e12);
        // Amount: small to medium (avoid overflow in project caps)
        amount = bound(amount, 10 ** loanDecimals, 100_000 * 10 ** loanDecimals);

        // Deploy token with custom decimals
        FuzzMockERC20 loanToken = new FuzzMockERC20(loanDecimals);

        // Set oracle prices
        vm.prank(owner);
        mockOracle.setPrice(address(loanToken), loanPrice);

        // Create project with this loanToken
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: amount + 1,
            softCap: amount / 2 + 1,
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
                loanToken: IERC20(address(loanToken)),
                stage: Fundraise.Stage.ComingSoon
            })
        });

        vm.prank(manager);
        uint256 pid = fundraise.createProject(proj, 1);

        // Mint and approve
        loanToken.mint(investor, amount);
        vm.prank(investor);
        IERC20(address(loanToken)).approve(address(fundraise), amount);

        // Sign and invest
        uint256 currentNonce = fundraise.userNonces(investor);
        bytes memory sig = _signInvest(investor, pid, amount, currentNonce + 1, inviter);

        vm.prank(investor);
        fundraise.investUpdateV2(pid, amount, currentNonce + 1, sig, inviter);

        // Calculate expected USD value
        uint256 usdcDecimals = 6;
        uint256 expectedUSD;
        if (loanDecimals >= usdcDecimals) {
            expectedUSD = Math.mulDiv(amount, loanPrice, 10 ** PRICE_DECIMALS * 10 ** (loanDecimals - usdcDecimals));
        } else {
            expectedUSD = Math.mulDiv(amount * 10 ** (usdcDecimals - loanDecimals), loanPrice, 10 ** PRICE_DECIMALS);
        }

        // Check bonus: should be awarded iff USD value >= 1000e6
        (uint256 investorUSDC,,,,) = rewardSystem.getProjectRewards(investor, pid);
        if (expectedUSD >= 1000e6) {
            assertEq(investorUSDC, 30e6, "Bonus should be awarded when USD >= 1000");
        } else {
            assertEq(investorUSDC, 0, "No bonus when USD < 1000");
        }
    }
}
