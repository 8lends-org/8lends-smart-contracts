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

}
