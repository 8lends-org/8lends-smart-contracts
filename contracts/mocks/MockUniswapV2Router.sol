// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock Uniswap V2 router: swapExactTokensForTokens at a fixed rate (e.g. 1 USDC = 1000
/// 8LNDS). Rate, reported factory and a forced failure are settable, so tests can drive both the
/// successful and the failing swap path.
contract MockUniswapV2Router {
    using SafeERC20 for IERC20;

    /// @dev amountOut = amountIn * rateNum / rateDenom (e.g. rateNum = 1000e18, rateDenom = 1e6)
    uint256 public rateNum;
    uint256 public rateDenom;

    /// @dev Reported by factory(). Zero reads as "no pair exists".
    address public factoryAddress;

    /// @dev When true every swap reverts, standing in for a broken pair.
    bool public shouldRevert;

    constructor(uint256 _rateNum, uint256 _rateDenom) {
        rateNum = _rateNum;
        rateDenom = _rateDenom;
    }

    function setRate(uint256 _rateNum, uint256 _rateDenom) external {
        rateNum = _rateNum;
        rateDenom = _rateDenom;
    }

    function setFactory(address _factory) external {
        factoryAddress = _factory;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function factory() external view returns (address) {
        return factoryAddress;
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
        require(!shouldRevert, "MockRouter: forced revert");
        require(path.length >= 2, "Invalid path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 amountOut = (amountIn * rateNum) / rateDenom;
        // Reverting is the point: the caller's slippage guard is only exercised if an underpaying
        // swap actually fails, and the fallback path depends on it.
        require(amountOut >= minAmountOut, "MockRouter: minOut not met");
        require(amountOut > 0, "Zero amountOut");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amountOut);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
        return amounts;
    }
}
