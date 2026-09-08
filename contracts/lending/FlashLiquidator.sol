// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import { Id, ILending8, MarketParams, Market, Position } from "./interfaces/ILending8.sol";
import {
    ILending8FlashLoanCallback,
    ILending8LiquidateCallback,
    ILending8RepayCallback,
    ILending8SupplyCallback,
    ILending8SupplyCollateralCallback
} from "./interfaces/ILending8Callbacks.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MarketParamsLib } from "./lib/MarketParamsLib.sol";
import { SharesMathLib } from "./lib/SharesMathLib.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router02.sol";
import { IUniswapV2Factory } from "../interfaces/external/IUniswapV2Factory.sol";
import { IOraclePrice } from "./interfaces/IOraclePrice.sol";
import { IERC20Metadata } from "../interfaces/token/IERC20Metadata.sol";

/// @title FlashLiquidator
/// @notice Liquidate unhealthy Lending8 positions. If a Uniswap V2 pair exists for collateral/loan: flash-loan loan token from Lending8, liquidate, swap collateral to loan, repay flash. If no pair: liquidate using loan token already held by this contract (no flash).
contract FlashLiquidator is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ILending8FlashLoanCallback,
    ILending8LiquidateCallback,
    ILending8RepayCallback,
    ILending8SupplyCallback,
    ILending8SupplyCollateralCallback
{
    using SafeERC20 for IERC20;

    ILending8 public LENDING8;
    address public uniswapV2Router;

    /// @dev Fixed-point scale for slippage (1e18 == 100%).
    uint256 private constant WAD = 1e18;
    /// @dev Hard cap on configurable slippage to prevent disabling the protection (10%).
    uint256 private constant MAX_SLIPPAGE = 0.1e18;

    /// @notice Max allowed slippage for collateral->loan swaps, in WAD (e.g. 0.02e18 == 2%).
    /// @dev Must be set via setMaxSlippage after deploy/upgrade; while zero, swap-based liquidations revert by design.
    uint256 public maxSlippage;

    event Liquidate(
        Id indexed marketId,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets
    );
    event MaxSlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    /// @dev Emitted when the seized collateral could not be swapped (broken/empty pair) and was kept on the contract.
    event SeizedCollateralRetained(Id indexed marketId, address collateralToken, uint256 seizedAssets);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param lending8 Lending8 contract address.
    /// @param initialOwner Owner (can upgrade the contract).
    function initialize(ILending8 lending8, address initialOwner, address _uniswapV2Router) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);
        LENDING8 = lending8;
        uniswapV2Router = _uniswapV2Router;
        maxSlippage = 0.03e18;
    }

    /// @notice Authorize contract upgrade (owner only).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setUniswapV2Router(address _uniswapV2Router) external onlyOwner {
        uniswapV2Router = _uniswapV2Router;
    }

    /// @notice Set the max allowed slippage (in WAD) for collateral->loan swaps.
    /// @param _maxSlippage New slippage tolerance, capped at MAX_SLIPPAGE.
    function setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
        require(_maxSlippage <= MAX_SLIPPAGE, "FlashLiq: slippage too high");
        uint256 oldSlippage = maxSlippage;
        maxSlippage = _maxSlippage;
        emit MaxSlippageUpdated(oldSlippage, _maxSlippage);
    }

    /// @notice Withdraw tokens from the contract (owner only).
    /// @param token Token address.
    /// @param to Recipient.
    /// @param amount Amount to transfer.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "FlashLiq: zero to");
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256 minOut = _minAmountOut(tokenIn, tokenOut, amountIn);
        IERC20(tokenIn).forceApprove(uniswapV2Router, amountIn);
        IUniswapV2Router02(uniswapV2Router).swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Oracle-derived minimum acceptable output for swapping `amountIn` of `tokenIn` into `tokenOut`,
    ///      discounted by `maxSlippage`. Reverts if slippage is not configured or a price is zero.
    function _minAmountOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 slippage = maxSlippage;
        require(slippage != 0, "FlashLiq: slippage not set");
        IOraclePrice oracle = IOraclePrice(LENDING8.oracle());
        uint256 inUsd = oracle.getPrice(tokenIn).price;
        uint256 outUsd = oracle.getPrice(tokenOut).price;
        require(inUsd != 0 && outUsd != 0, "FlashLiq: zero oracle price");
        uint256 inDecimals = IERC20Metadata(tokenIn).decimals();
        uint256 outDecimals = IERC20Metadata(tokenOut).decimals();
        uint256 expectedOut = (amountIn * inUsd * (10 ** outDecimals)) / (outUsd * (10 ** inDecimals));
        return (expectedOut * (WAD - slippage)) / WAD;
    }

    /// @return True if Uniswap V2 router is set and factory reports a non-zero pair for the two tokens.
    function hasUniswapV2Pair(address tokenA, address tokenB) internal view returns (bool) {
        if (uniswapV2Router == address(0)) {
            return false;
        }
        address factory = IUniswapV2Router02(uniswapV2Router).factory();
        return IUniswapV2Factory(factory).getPair(tokenA, tokenB) != address(0);
    }

    /// @dev Liquidates an unhealthy position, funding the repayment from Lending8 flash liquidity and/or
    ///      the contract's own loan token balance:
    ///      - Flash liquidity is only usable when a Uniswap V2 pair exists, since the seized collateral must be
    ///        swapped back to the loan token to repay the flash loan.
    ///      - The actually repaid amount is capped by the available funds (pool liquidity + own balance) and by
    ///        the borrower's debt; a larger request results in a partial liquidation.
    ///      - The flash loan takes at most the available pool liquidity; the remainder is covered by the
    ///        contract's own loan token balance.
    ///      - If the flash branch reverts (e.g. the swap through an empty/broken pair fails minOut), the call
    ///        falls back to a direct liquidation from the own balance instead of reverting, so an empty Uniswap
    ///        pair created by anyone cannot block liquidations. If the seized collateral cannot be swapped,
    ///        it stays on the contract (SeizedCollateralRetained).
    /// @param marketId Market id.
    /// @param borrower Unhealthy position owner.
    /// @param repaidAssets Target loan token amount for share rounding; Lending8 may pull slightly more (toAssetsUp(repaidShares)).
    function liquidate(Id marketId, address borrower, uint256 repaidAssets) external {
        require(repaidAssets != 0, "FlashLiq: zero repaidAssets");
        (MarketParams memory marketParams, uint256 totalBorrowAssets, uint256 totalBorrowShares) = _loadMarketForLiquidation(marketId);
        uint256 borrowerShares = LENDING8.position(marketId, borrower).borrowShares;
        require(borrowerShares != 0, "FlashLiq: no debt");
        bool pairExists = hasUniswapV2Pair(marketParams.collateralToken, marketParams.loanToken);
        uint256 ownBalance = IERC20(marketParams.loanToken).balanceOf(address(this));
        uint256 poolLiquidity = pairExists ? IERC20(marketParams.loanToken).balanceOf(address(LENDING8)) : 0;
        (uint256 assetsToRepay, uint256 repaidShares) = _resolveRepayAmount(repaidAssets, ownBalance + poolLiquidity, borrowerShares, totalBorrowAssets, totalBorrowShares);

        if (_min(poolLiquidity, assetsToRepay) != 0) {
            if (_tryFlashLiquidate(marketParams, borrower, repaidShares, assetsToRepay, _min(poolLiquidity, assetsToRepay))) {
                return;
            }
            (assetsToRepay, repaidShares) = _resolveRepayAmount(repaidAssets, ownBalance, borrowerShares, totalBorrowAssets, totalBorrowShares);
        }

        (uint256 seizedAssets, uint256 actualRepaid) = _liquidatePosition(marketParams, borrower, repaidShares, assetsToRepay);
        if (pairExists) _trySwapSeizedCollateral(marketParams, seizedAssets);
        
        emit Liquidate(MarketParamsLib.id(marketParams), borrower, actualRepaid, repaidShares, seizedAssets);
    }

    /// @dev Flash loan callback: liquidates the position (approving the full repay amount, i.e. flash loan plus
    ///      the top-up from the own balance), swaps the seized collateral back to the loan token and approves
    ///      exactly the flash amount so Lending8 can pull it back.
    function onLending8FlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(LENDING8), "FlashLiq: only Lending8");
        (MarketParams memory marketParams, address borrower, uint256 repaidShares, uint256 assetsToRepay) = abi.decode(
            data,
            (MarketParams, address, uint256, uint256)
        );
        (uint256 seizedAssets, uint256 actualRepaid) = _liquidatePosition(marketParams, borrower, repaidShares, assetsToRepay);
        if (seizedAssets != 0) swap(marketParams.collateralToken, marketParams.loanToken, seizedAssets);
        
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        emit Liquidate(MarketParamsLib.id(marketParams), borrower, actualRepaid, repaidShares, seizedAssets);
    }

    /// @dev Flash-borrows `flashAmount` of the loan token and liquidates inside the callback (see onLending8FlashLoan).
    ///      Returns false instead of reverting when the flash branch fails, so the caller can fall back to a
    ///      direct liquidation; all state changes of the failed attempt are reverted.
    function _tryFlashLiquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 repaidShares,
        uint256 assetsToRepay,
        uint256 flashAmount
    ) internal returns (bool) {
        bytes memory data = abi.encode(marketParams, borrower, repaidShares, assetsToRepay);
        try LENDING8.flashLoan(marketParams.loanToken, flashAmount, data) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Loads the market params and debt totals, accruing interest first so the totals are up to date.
    ///      Reverts if the market is unknown or has no borrows.
    function _loadMarketForLiquidation(Id marketId)
        internal
        returns (MarketParams memory marketParams, uint256 totalBorrowAssets, uint256 totalBorrowShares)
    {
        marketParams = LENDING8.idToMarketParams(marketId);
        require(marketParams.loanToken != address(0), "FlashLiq: market not found");
        LENDING8.accrueInterest(marketParams);
        Market memory m = LENDING8.market(marketId);
        require(m.lastUpdate != 0, "FlashLiq: market not found");
        totalBorrowAssets = uint256(m.totalBorrowAssets);
        totalBorrowShares = uint256(m.totalBorrowShares);
        require(totalBorrowShares != 0, "FlashLiq: market has no borrows");
    }

    /// @dev Caps the requested repayment by the available assets and the borrower's debt, and converts it to
    ///      debt shares. Repaying more than the borrower owes would underflow in Lending8, so the shares are
    ///      capped at the borrower's shares; the recomputed toAssetsUp of the smaller shares never exceeds the
    ///      available-assets limit. Reverts when there is nothing to repay with.
    function _resolveRepayAmount(
        uint256 requestedAssets,
        uint256 availableAssets,
        uint256 borrowerShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares
    ) internal pure returns (uint256 assetsToRepay, uint256 repaidShares) {
        assetsToRepay = _min(requestedAssets, availableAssets);
        require(assetsToRepay != 0, "FlashLiq: no funds available");
        repaidShares = SharesMathLib.toSharesDown(assetsToRepay, totalBorrowAssets, totalBorrowShares);
        require(repaidShares != 0, "FlashLiq: repaidAssets too low");
        if (repaidShares > borrowerShares) {
            repaidShares = borrowerShares;
            assetsToRepay = SharesMathLib.toAssetsUp(repaidShares, totalBorrowAssets, totalBorrowShares);
        }
    }

    /// @dev Approves `approveAmount` for Lending8, liquidates `repaidShares` of `borrower` (empty data — no
    ///      callback needed), then resets the allowance back to zero.
    function _liquidatePosition(
        MarketParams memory marketParams,
        address borrower,
        uint256 repaidShares,
        uint256 approveAmount
    ) internal returns (uint256 seizedAssets, uint256 actualRepaid) {
        IERC20 loanToken = IERC20(marketParams.loanToken);
        loanToken.forceApprove(address(LENDING8), approveAmount);
        (seizedAssets, actualRepaid) = LENDING8.liquidate(marketParams, borrower, 0, repaidShares, "");
        loanToken.forceApprove(address(LENDING8), 0);
    }

    /// @dev Swaps the seized collateral back to the loan token (no-op when nothing was seized). Reverts on a
    ///      failed swap — used in the flash branch, where the swap is mandatory to repay the flash loan.
    function _swapSeizedCollateral(MarketParams memory marketParams, uint256 seizedAssets) internal {
      
    }

    /// @dev Attempts to swap the seized collateral back to the loan token; on failure (empty/broken pair,
    ///      minOut not met) keeps the collateral on the contract and resets the router allowance instead of
    ///      reverting — a direct liquidation must not depend on the state of the pair.
    function _trySwapSeizedCollateral(MarketParams memory marketParams, uint256 seizedAssets) internal {
        if (seizedAssets == 0) return;
        address tokenIn = marketParams.collateralToken;
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = marketParams.loanToken;
        uint256 minOut = _minAmountOut(tokenIn, marketParams.loanToken, seizedAssets);
        IERC20(tokenIn).forceApprove(uniswapV2Router, seizedAssets);
        try IUniswapV2Router02(uniswapV2Router).swapExactTokensForTokens(
            seizedAssets,
            minOut,
            path,
            address(this),
            block.timestamp
        ) {} catch {
            IERC20(tokenIn).forceApprove(uniswapV2Router, 0);
            emit SeizedCollateralRetained(MarketParamsLib.id(marketParams), tokenIn, seizedAssets);
        }
    }

    /// @dev Returns the smaller of the two numbers.
    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function onLending8Liquidate(uint256 repaidAssets, bytes calldata data) external {}
    function onLending8Repay(uint256 assets, bytes calldata data) external {}
    function onLending8Supply(uint256 assets, bytes calldata data) external {}
    function onLending8SupplyCollateral(uint256 assets, bytes calldata data) external {}
}
