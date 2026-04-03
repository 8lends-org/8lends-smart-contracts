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

/// @title FlashLiquidator
/// @notice Liquidate unhealthy Lending8 positions using a flash loan: caller passes marketId, borrower and loan token amount; contract borrows via flash loan, liquidates, then repays flash from caller's approved loan token. Caller must approve loan token to this contract.
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

    /// @notice Liquidate an unhealthy position via flash loan. Contract borrows loan token from Lending8, calls liquidate, then repays the flash by pulling loan token from caller. Caller must approve this contract for the loan token (actualRepaidAssets).
    /// @param marketId Market id.
    /// @param borrower Unhealthy position owner.
    /// @param repaidAssets Amount of loan token to repay (in token units). Contract computes repaidShares; Lending8 may pull slightly more (toAssetsUp(repaidShares)).
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
        bytes memory data = abi.encode(marketParams, borrower, repaidShares);
        LENDING8.flashLoan(marketParams.loanToken, repaidAssets, data);
    }

    function onLending8FlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(LENDING8), "FlashLiq: only Lending8");
        (MarketParams memory marketParams, address borrower, uint256 repaidShares) = abi.decode(
            data,
            (MarketParams, address, uint256)
        );
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        (uint256 seizedAssets, ) = LENDING8.liquidate(marketParams, borrower, 0, repaidShares, "0x");
        swap(marketParams.collateralToken, marketParams.loanToken, seizedAssets);
        IERC20(marketParams.loanToken).forceApprove(address(LENDING8), assets);
        emit Liquidate(MarketParamsLib.id(marketParams), borrower, assets, repaidShares, seizedAssets);
    }

    function onLending8Liquidate(uint256 repaidAssets, bytes calldata data) external {}
    function onLending8Repay(uint256 assets, bytes calldata data) external {}
    function onLending8Supply(uint256 assets, bytes calldata data) external {}
    function onLending8SupplyCollateral(uint256 assets, bytes calldata data) external {}
}
