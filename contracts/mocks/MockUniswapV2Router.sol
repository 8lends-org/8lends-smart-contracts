// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock Uniswap V2 router for tests: swapExactTokensForTokens at fixed rate (e.g. 1 USDC = 1000 8LNDS).
contract MockUniswapV2Router {
    using SafeERC20 for IERC20;

    /// @dev amountOut = amountIn * rateNum / rateDenom (e.g. rateNum = 1000e18, rateDenom = 1e6)
    uint256 public rateNum;
    uint256 public rateDenom;

    constructor(uint256 _rateNum, uint256 _rateDenom) {
        rateNum = _rateNum;
        rateDenom = _rateDenom;
    }

    function factory() external pure returns (address) {
        return address(0);
    }

    function WETH() external pure returns (address) {
        return address(0);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 minAmountOut,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * rateNum) / rateDenom;
        if (amountOut < minAmountOut) amountOut = minAmountOut;
        require(amountOut > 0, "Zero amountOut");
        IERC20(tokenOut).safeTransfer(to, amountOut);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
        return amounts;
    }
}
