// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Deterministic Uniswap V2 Router mock for testing
/// @dev Fixed price: 1 USDC (6 dec) = 100 tokens (18 dec)
///      i.e. 1e6 USDC = 100e18 tokens, so 1 token = 0.01 USDC
contract MockUniswapV2Router {
    using SafeERC20 for IERC20;

    address public tokenAddress;
    address public usdcAddress;

    // Price: 1 USDC = TOKENS_PER_USDC tokens
    // With decimals: 1e6 USDC = 100e18 tokens
    uint256 public constant TOKENS_PER_USDC = 100; // 100 tokens per 1 USDC

    bool public shouldRevert;

    constructor(address _token, address _usdc) {
        tokenAddress = _token;
        usdcAddress = _usdc;
    }

    /// @notice Toggle revert mode (for testing Uniswap failure scenarios)
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        require(!shouldRevert, "MockRouter: reverted");
        require(path.length == 2, "MockRouter: invalid path");
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        if (path[0] == usdcAddress && path[1] == tokenAddress) {
            // USDC -> Token: multiply by TOKENS_PER_USDC, adjust decimals (6 -> 18)
            amounts[1] = amountIn * TOKENS_PER_USDC * 1e12;
        } else if (path[0] == tokenAddress && path[1] == usdcAddress) {
            // Token -> USDC: divide by TOKENS_PER_USDC, adjust decimals (18 -> 6)
            amounts[1] = amountIn / (TOKENS_PER_USDC * 1e12);
        } else {
            revert("MockRouter: unknown pair");
        }
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        require(!shouldRevert, "MockRouter: reverted");
        require(path.length == 2, "MockRouter: invalid path");
        amounts = new uint256[](2);
        amounts[1] = amountOut;

        if (path[0] == usdcAddress && path[1] == tokenAddress) {
            // Need amountOut tokens, how much USDC?
            amounts[0] = amountOut / (TOKENS_PER_USDC * 1e12);
        } else if (path[0] == tokenAddress && path[1] == usdcAddress) {
            // Need amountOut USDC, how many tokens?
            amounts[0] = amountOut * TOKENS_PER_USDC * 1e12;
        } else {
            revert("MockRouter: unknown pair");
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        require(!shouldRevert, "MockRouter: reverted");
        require(path.length == 2, "MockRouter: invalid path");

        amounts = new uint256[](2);
        amounts[0] = amountIn;

        if (path[0] == usdcAddress && path[1] == tokenAddress) {
            amounts[1] = amountIn * TOKENS_PER_USDC * 1e12;
        } else if (path[0] == tokenAddress && path[1] == usdcAddress) {
            amounts[1] = amountIn / (TOKENS_PER_USDC * 1e12);
        } else {
            revert("MockRouter: unknown pair");
        }

        require(amounts[1] >= amountOutMin, "MockRouter: insufficient output");

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).safeTransfer(to, amounts[1]);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        require(!shouldRevert, "MockRouter: reverted");
        require(path.length == 2, "MockRouter: invalid path");

        amounts = new uint256[](2);
        amounts[1] = amountOut;

        if (path[0] == usdcAddress && path[1] == tokenAddress) {
            amounts[0] = amountOut / (TOKENS_PER_USDC * 1e12);
        } else if (path[0] == tokenAddress && path[1] == usdcAddress) {
            amounts[0] = amountOut * TOKENS_PER_USDC * 1e12;
        } else {
            revert("MockRouter: unknown pair");
        }

        require(amounts[0] <= amountInMax, "MockRouter: excessive input");

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amounts[0]);
        IERC20(path[1]).safeTransfer(to, amountOut);
    }
}
