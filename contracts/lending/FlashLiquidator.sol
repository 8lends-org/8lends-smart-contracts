// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import { Id, ILending8, MarketParams, Market } from "./interfaces/ILending8.sol";
import { ILending8FlashLoanCallback } from "./interfaces/ILending8Callbacks.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MarketParamsLib } from "./lib/MarketParamsLib.sol";
import { SharesMathLib } from "./lib/SharesMathLib.sol";
import { IUniswapV2Router02 } from "../reward-system/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title FlashLiquidator
/// @notice Liquidate unhealthy Lending8 positions using a flash loan; collateral is swapped to loan token via Uniswap to repay the flash loan.
contract FlashLiquidator is Initializable, UUPSUpgradeable, OwnableUpgradeable, ILending8FlashLoanCallback {
    using SafeERC20 for IERC20;

    uint256 private constant SWAP_DEADLINE_BUFFER = 300;

    ILending8 public LENDING8;
    IUniswapV2Router02 public swapRouter;

    event FlashLiquidate(MarketParams marketParams, address borrower, uint256 seizedAssets, uint256 repaidShares, uint256 assets);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param lending8 Lending8 contract address.
    /// @param initialOwner Owner (can upgrade the contract). Call setSwapRouter before flashLiquidate.
    function initialize(ILending8 lending8, address initialOwner) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);
        LENDING8 = lending8;
    }

    /// @notice Set Uniswap V2 router (owner only).
    function setSwapRouter(address swapRouter_) external onlyOwner {
        swapRouter = IUniswapV2Router02(swapRouter_);
    }

    /// @notice Authorize contract upgrade (owner only).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Liquidate a position by repaying `repaidShares` of debt using a flash loan; received collateral is swapped to loan token to repay the flash loan.
    /// @param marketParams Market parameters (must match an existing market).
    /// @param borrower Unhealthy position owner.
    /// @param repaidShares Amount of borrow shares to repay (debt to liquidate).
    /// @param swapPath Swap path: first element = marketParams.collateralToken, last = marketParams.loanToken (e.g. [collateral, loan] or [collateral, WETH, loan]).
    /// @param minLoanTokenOut Minimum amount of loan token to receive from the swap (must be >= repaidAssets to cover flash loan return).
    function flashLiquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 repaidShares,
        address[] calldata swapPath,
        uint256 minLoanTokenOut
    ) external {
        require(repaidShares != 0, "zero repaidShares");
        require(address(swapRouter) != address(0), "swap router not set");
        require(swapPath.length >= 2, "invalid path");
        require(swapPath[0] == marketParams.collateralToken && swapPath[swapPath.length - 1] == marketParams.loanToken, "path endpoints");
        LENDING8.accrueInterest(marketParams);
        Id marketId = MarketParamsLib.id(marketParams);
        Market memory m = LENDING8.market(marketId);
        uint256 repaidAssets = SharesMathLib.toAssetsUp(
            repaidShares,
            m.totalBorrowAssets,
            m.totalBorrowShares
        );
        require(minLoanTokenOut >= repaidAssets, "minOut < repaid");
        uint256 flashAmount = repaidAssets + 1;
        bytes memory data = abi.encode(marketParams, borrower, repaidShares, swapPath, minLoanTokenOut);
        LENDING8.flashLoan(marketParams.loanToken, flashAmount, data);
    }

    /// @inheritdoc ILending8FlashLoanCallback
    function onLending8FlashLoan(uint256 assets, bytes calldata data) external override {
        require(msg.sender == address(LENDING8), "only Lending8");
        (MarketParams memory marketParams, address borrower, uint256 repaidShares, address[] memory swapPath, uint256 minLoanTokenOut) =
            abi.decode(data, (MarketParams, address, uint256, address[], uint256));
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        (uint256 seizedAssets,) = LENDING8.liquidate(marketParams, borrower, 0, repaidShares, "");
        require(seizedAssets != 0, "no collateral");
        IERC20(marketParams.collateralToken).forceApprove(address(swapRouter), seizedAssets);
        swapRouter.swapExactTokensForTokens(
            seizedAssets,
            minLoanTokenOut,
            swapPath,
            address(this),
            block.timestamp + SWAP_DEADLINE_BUFFER
        );
        IERC20(marketParams.collateralToken).forceApprove(address(swapRouter), 0);
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        emit FlashLiquidate(marketParams, borrower, seizedAssets, repaidShares, assets);
    }
}
