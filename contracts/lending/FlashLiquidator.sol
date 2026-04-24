// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import { Id, ILending8, MarketParams, Market } from "./interfaces/ILending8.sol";
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
import { IUniswapV2Factory } from "../interfaces/IUniswapV2Factory.sol";

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

    event Liquidate(
        Id indexed marketId,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets
    );

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
    }

    /// @notice Authorize contract upgrade (owner only).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setUniswapV2Router(address _uniswapV2Router) external onlyOwner {
        uniswapV2Router = _uniswapV2Router;
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
        IERC20(tokenIn).approve(uniswapV2Router, amountIn);
        IUniswapV2Router02(uniswapV2Router).swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);
    }

    /// @return True if Uniswap V2 router is set and factory reports a non-zero pair for the two tokens.
    function hasUniswapV2Pair(address tokenA, address tokenB) internal view returns (bool) {
        if (uniswapV2Router == address(0)) {
            return false;
        }
        address factory = IUniswapV2Router02(uniswapV2Router).factory();
        return IUniswapV2Factory(factory).getPair(tokenA, tokenB) != address(0);
    }

    /// @notice Liquidate an unhealthy position. With a V2 pair: flash loan then swap. Without: uses this contract's loan token balance (no flash).
    /// @param marketId Market id.
    /// @param borrower Unhealthy position owner.
    /// @param repaidAssets Target loan token amount for share rounding; Lending8 may pull slightly more (toAssetsUp(repaidShares)).
    function liquidate(Id marketId, address borrower, uint256 repaidAssets) external {
        require(repaidAssets != 0, "FlashLiq: zero repaidAssets");
        MarketParams memory marketParams = LENDING8.idToMarketParams(marketId);
        require(marketParams.loanToken != address(0), "FlashLiq: market not found");
        LENDING8.accrueInterest(marketParams);
        Market memory m = LENDING8.market(marketId);
        require(m.lastUpdate != 0, "FlashLiq: market not found");
        uint256 totalBorrowAssets = uint256(m.totalBorrowAssets);
        uint256 totalBorrowShares = uint256(m.totalBorrowShares);
        require(totalBorrowShares != 0, "FlashLiq: market has no borrows");
        uint256 repaidShares = SharesMathLib.toSharesDown(repaidAssets, totalBorrowAssets, totalBorrowShares);
        require(repaidShares != 0, "FlashLiq: repaidAssets too low");
        if (hasUniswapV2Pair(marketParams.collateralToken, marketParams.loanToken)) {
            bytes memory data = abi.encode(marketParams, borrower, repaidShares);
            LENDING8.flashLoan(marketParams.loanToken, repaidAssets, data);
            return;
        }
        IERC20 loanToken = IERC20(marketParams.loanToken);
        require(loanToken.balanceOf(address(this)) >= repaidAssets, "FlashLiq: insufficient loan balance");
        loanToken.forceApprove(address(LENDING8), type(uint256).max);
        (uint256 seizedAssets, uint256 actualRepaid) = LENDING8.liquidate(
            marketParams,
            borrower,
            0,
            repaidShares,
            "0x"
        );
        loanToken.forceApprove(address(LENDING8), 0);
        emit Liquidate(MarketParamsLib.id(marketParams), borrower, actualRepaid, repaidShares, seizedAssets);
    }

    function onLending8FlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(LENDING8), "FlashLiq: only Lending8");
        (MarketParams memory marketParams, address borrower, uint256 repaidShares) = abi.decode(
            data,
            (MarketParams, address, uint256)
        );
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        (uint256 seizedAssets, uint256 actualRepaid) = LENDING8.liquidate(marketParams, borrower, 0, repaidShares, "0x");
        swap(marketParams.collateralToken, marketParams.loanToken, seizedAssets);
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        emit Liquidate(MarketParamsLib.id(marketParams), borrower, actualRepaid, repaidShares, seizedAssets);
    }

    function onLending8Liquidate(uint256 repaidAssets, bytes calldata data) external {}
    function onLending8Repay(uint256 assets, bytes calldata data) external {}
    function onLending8Supply(uint256 assets, bytes calldata data) external {}
    function onLending8SupplyCollateral(uint256 assets, bytes calldata data) external {}
}
