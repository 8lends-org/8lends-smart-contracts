// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import { Id, ILending8, MarketParams, Market } from "./interfaces/ILending8.sol";
import { ILending8FlashLoanCallback } from "./interfaces/ILending8Callbacks.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { MarketParamsLib } from "./lib/MarketParamsLib.sol";
import { SharesMathLib } from "./lib/SharesMathLib.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title FlashLiquidator
/// @notice Liquidate unhealthy Lending8 positions using a flash loan (no upfront loan token balance).
contract FlashLiquidator is Initializable, UUPSUpgradeable, OwnableUpgradeable, ILending8FlashLoanCallback {
    ILending8 public LENDING8;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param lending8 Lending8 contract address.
    /// @param initialOwner Owner (can upgrade the contract).
    function initialize(ILending8 lending8, address initialOwner) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(initialOwner);
        LENDING8 = lending8;
    }

    /// @notice Authorize contract upgrade (owner only).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Liquidate a position by repaying `repaidShares` of debt using a flash loan.
    /// @param marketParams Market parameters (must match an existing market).
    /// @param borrower Unhealthy position owner.
    /// @param repaidShares Amount of borrow shares to repay (debt to liquidate).
    function flashLiquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 repaidShares
    ) external {
        require(repaidShares != 0, "zero repaidShares");
        LENDING8.accrueInterest(marketParams);
        Id marketId = MarketParamsLib.id(marketParams);
        Market memory m = LENDING8.market(marketId);
        uint256 repaidAssets = SharesMathLib.toAssetsUp(
            repaidShares,
            m.totalBorrowAssets,
            m.totalBorrowShares
        );
        bytes memory data = abi.encode(marketParams, borrower, repaidShares);
        LENDING8.flashLoan(marketParams.loanToken, repaidAssets, data);
    }

    /// @notice Test flash loan: borrow and return only (no liquidation). Owner only. Use to verify Lending8 flash loan + approve/transferFrom.
    /// @param loanToken Loan token address (must have liquidity in Lending8).
    /// @param amount Amount to flash borrow.
    function testFlashLoan(address loanToken, uint256 amount) external onlyOwner {
        require(amount != 0, "zero amount");
        bytes memory data = abi.encode(true, loanToken);
        LENDING8.flashLoan(loanToken, amount, data);
    }

    /// @inheritdoc ILending8FlashLoanCallback
    function onLending8FlashLoan(uint256 assets, bytes calldata data) external override {
        require(msg.sender == address(LENDING8), "only Lending8");
        if (data.length == 64) {
            (bool isTest, address loanTokenAddr) = abi.decode(data, (bool, address));
            if (isTest) {
                IERC20 token = IERC20(loanTokenAddr);
                token.approve(address(LENDING8), 0);
                token.approve(address(LENDING8), assets);
                return;
            }
        }
        (MarketParams memory marketParams, address borrower, uint256 repaidShares) =
            abi.decode(data, (MarketParams, address, uint256));
        IERC20 loanToken = IERC20(marketParams.loanToken);
        loanToken.approve(address(LENDING8), 0);
        loanToken.approve(address(LENDING8), assets);
        LENDING8.liquidate(marketParams, borrower, 0, repaidShares, "");
    }
}
