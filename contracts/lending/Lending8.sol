// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import { Id, ILending8StaticTyping, ILending8Base, MarketParams, Position, Market, Authorization, Signature } from "./interfaces/ILending8.sol";
import { ILending8LiquidateCallback, ILending8RepayCallback, ILending8SupplyCallback, ILending8SupplyCollateralCallback, ILending8FlashLoanCallback } from "./interfaces/ILending8Callbacks.sol";
import { IIrm } from "./interfaces/IIrm.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC20Metadata } from "../interfaces/token/IERC20Metadata.sol";
import { IOraclePrice } from "./interfaces/IOraclePrice.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./lib/ConstantsLib.sol";
import { UtilsLib } from "./lib/UtilsLib.sol";
import { EventsLib } from "./lib/EventsLib.sol";
import { ErrorsLib } from "./lib/ErrorsLib.sol";
import { MathLib, WAD } from "./lib/MathLib.sol";
import { SharesMathLib } from "./lib/SharesMathLib.sol";
import { MarketParamsLib } from "./lib/MarketParamsLib.sol";
import { SafeTransferLib } from "./lib/SafeTransferLib.sol";

/// @title Lending8
/// @author 8lends
/// @notice Isolated lending protocol: separate markets (loan/collateral pair + IRM + LLTV), one global oracle; supply/borrow in shares, liquidations, flash loans.
contract Lending8 is Initializable, UUPSUpgradeable, OwnableUpgradeable, ILending8StaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* STORAGE (UPGRADEABLE) */

    /// @notice Domain separator for EIP-712 signatures (authorization, etc.).
    bytes32 public DOMAIN_SEPARATOR;

    /* STORAGE */

    /// @notice Address that receives the fee share from interest (in supply shares).
    address public feeRecipient;
    /// @notice User position in a market: supplyShares, borrowShares, collateral (for each market Id and address).
    mapping(Id => mapping(address => Position)) public position;
    /// @notice Market state: totalSupplyAssets/Shares, totalBorrowAssets/Shares, lastUpdate, fee.
    mapping(Id => Market) public market;
    /// @notice Allowed IRM (Interest Rate Model) addresses; only these can be used when creating a market.
    mapping(address => bool) public isIrmEnabled;
    /// @notice Allowed LLTV (Loan-to-Value, in WAD) values; only these are valid when creating a market.
    mapping(uint256 => bool) public isLltvEnabled;
    /// @notice Authorizer has permitted authorized to manage their positions (withdraw, borrow, withdrawCollateral, etc.).
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @notice Nonce for authorization signatures (incremented when using setAuthorizationWithSig).
    mapping(address => uint256) public nonce;
    /// @notice Market parameters by Id: loanToken, collateralToken, irm, lltv (used for calculations and checks).
    mapping(Id => MarketParams) public idToMarketParams;
    /// @notice Global oracle (getPrice(token).price = USD price); used to derive collateral/loan price (scale 1e36). Append-only for upgrade safety.
    address public oracle;


    /* CONSTRUCTOR */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER */

    /// @param newOwner Contract owner address (manages settings, IRM, LLTV, fee).
    function initialize(address newOwner) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(newOwner);

        DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));

        emit EventsLib.SetOwner(newOwner);
    }

    /// @notice Authorize contract upgrade (owner only).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc ILending8Base
    function owner() public view override(OwnableUpgradeable, ILending8Base) returns (address) {
        return super.owner();
    }

    /* ONLY OWNER FUNCTIONS */

    /// @notice Enable use of IRM (interest rate model) when creating markets.
    function enableIrm(address irm) external onlyOwner {
        require(!isIrmEnabled[irm], ErrorsLib.ALREADY_SET);

        isIrmEnabled[irm] = true;

        emit EventsLib.EnableIrm(irm);
    }

    /// @notice Enable use of LLTV (max collateral LTV) when creating markets; lltv < WAD.
    function enableLltv(uint256 lltv) external onlyOwner {
        require(!isLltvEnabled[lltv], ErrorsLib.ALREADY_SET);
        require(lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);

        isLltvEnabled[lltv] = true;

        emit EventsLib.EnableLltv(lltv);
    }

    /// @notice Set the global oracle (must implement getPrice(token) returning struct with .price in USD).
    function setOracle(address newOracle) external onlyOwner {
        oracle = newOracle;
        emit EventsLib.SetOracle(newOracle);
    }

    /// @notice Set market fee (share of accrued interest, in WAD); interest is accrued before changing.
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(newFee != market[marketId].fee, ErrorsLib.ALREADY_SET);
        require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

        // Accrue interest using the previous fee set before changing it.
        _accrueInterest(marketParams, marketId);

        // Safe "unchecked" cast.
        market[marketId].fee = uint128(newFee);

        emit EventsLib.SetFee(marketId, newFee);
    }

    /// @notice Set the fee recipient address (supply shares from interest).
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @notice Create a new market (loanToken, collateralToken, irm, lltv). IRM and LLTV must be enabled; oracle is global. Reverts if oracle not set or price for collateral/loan is 0.
    function createMarket(MarketParams memory marketParams) external onlyOwner {
        Id marketId = marketParams.id();
        require(oracle != address(0), ErrorsLib.ZERO_ADDRESS);
        require(isIrmEnabled[marketParams.irm], ErrorsLib.IRM_NOT_ENABLED);
        require(isLltvEnabled[marketParams.lltv], ErrorsLib.LLTV_NOT_ENABLED);
        require(market[marketId].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);
        uint256 collateralUsd = IOraclePrice(oracle).getPrice(marketParams.collateralToken).price;
        uint256 loanUsd = IOraclePrice(oracle).getPrice(marketParams.loanToken).price;
        require(collateralUsd > 0 && loanUsd > 0, ErrorsLib.ZERO_ORACLE_PRICE);

        // Safe "unchecked" cast.
        market[marketId].lastUpdate = uint128(block.timestamp);
        idToMarketParams[marketId] = marketParams;

        emit EventsLib.CreateMarket(marketId, marketParams);

        // Call to initialize the IRM in case it is stateful.
        if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[marketId]);
    }

    /* SUPPLY MANAGEMENT */

    /// @notice Supply loan token to the market: either assets or shares (one of them must be 0). Credit goes to onBehalf. data is optional callback onLending8Supply.
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, marketId);

        if (assets > 0)
            shares = assets.toSharesDown(market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares);
        else assets = shares.toAssetsUp(market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares);

        position[marketId][onBehalf].supplyShares += shares;
        market[marketId].totalSupplyShares += shares.toUint128();
        market[marketId].totalSupplyAssets += assets.toUint128();

        emit EventsLib.Supply(marketId, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) ILending8SupplyCallback(msg.sender).onLending8Supply(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /// @notice Withdraw loan token from the market (assets or shares). Can be called by onBehalf or authorized address. Market liquidity is checked after withdrawal.
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, marketId);

        if (assets > 0)
            shares = assets.toSharesUp(market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares);
        else assets = shares.toAssetsDown(market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares);

        position[marketId][onBehalf].supplyShares -= shares;
        market[marketId].totalSupplyShares -= shares.toUint128();
        market[marketId].totalSupplyAssets -= assets.toUint128();

        require(
            market[marketId].totalBorrowAssets <= market[marketId].totalSupplyAssets,
            ErrorsLib.INSUFFICIENT_LIQUIDITY
        );

        emit EventsLib.Withdraw(marketId, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /* BORROW MANAGEMENT */

    /// @notice Borrow loan token (assets or shares). Can be called by onBehalf or authorized address. Position health (LLTV) and market liquidity are checked.
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        return _borrow(marketParams, assets, shares, onBehalf, receiver);
    }

    /// @dev Internal borrow logic; preserves msg.sender for authorization.
    function _borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) internal returns (uint256, uint256) {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, marketId);

        if (assets > 0)
            shares = assets.toSharesUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        else assets = shares.toAssetsDown(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);

        position[marketId][onBehalf].borrowShares += shares.toUint128();
        market[marketId].totalBorrowShares += shares.toUint128();
        market[marketId].totalBorrowAssets += assets.toUint128();

        require(_isHealthy(marketParams, marketId, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
        require(
            market[marketId].totalBorrowAssets <= market[marketId].totalSupplyAssets,
            ErrorsLib.INSUFFICIENT_LIQUIDITY
        );

        emit EventsLib.Borrow(marketId, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /// @notice Repay market debt (assets or shares). Credit goes to onBehalf. data is optional callback onLending8Repay.
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, marketId);

        if (assets > 0)
            shares = assets.toSharesDown(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        else assets = shares.toAssetsUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);

        position[marketId][onBehalf].borrowShares -= shares.toUint128();
        market[marketId].totalBorrowShares -= shares.toUint128();
        market[marketId].totalBorrowAssets = UtilsLib
            .zeroFloorSub(market[marketId].totalBorrowAssets, assets)
            .toUint128();

        // `assets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Repay(marketId, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) ILending8RepayCallback(msg.sender).onLending8Repay(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* COLLATERAL MANAGEMENT */

    /// @notice Supply collateral to the market on behalf of onBehalf. Interest is not accrued (gas savings). data is optional callback onLending8SupplyCollateral.
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external {
        _supplyCollateral(marketParams, assets, onBehalf, data);
    }

    /// @dev Internal supply collateral logic; preserves msg.sender for callback and transfer.
    function _supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) internal {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        position[marketId][onBehalf].collateral += assets.toUint128();

        emit EventsLib.SupplyCollateral(marketId, msg.sender, onBehalf, assets);

        if (data.length > 0) ILending8SupplyCollateralCallback(msg.sender).onLending8SupplyCollateral(assets, data);

        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @notice Supply collateral and borrow in one transaction (atomic).
    function supplyCollateralAndBorrowLoan(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 loanAssets,
        uint256 loanShares,
        address onBehalf,
        address receiver,
        bytes calldata data
    ) external returns (uint256, uint256) {
        _supplyCollateral(marketParams, collateralAssets, onBehalf, data);
        return _borrow(marketParams, loanAssets, loanShares, onBehalf, receiver);
    }

    /// @notice Withdraw collateral from the market. Can be called by onBehalf or authorized address. Position health (LLTV) is checked after withdrawal.
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, marketId);

        position[marketId][onBehalf].collateral -= assets.toUint128();

        require(_isHealthy(marketParams, marketId, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);

        emit EventsLib.WithdrawCollateral(marketId, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /* LIQUIDATION */

    /// @notice Liquidate an unhealthy position: liquidator repays debt (either repaidShares or seizedAssets is specified), seizes collateral (seizedAssets). Liquidator bonus is accounted via liquidationIncentiveFactor. data is optional callback onLending8Liquidate.
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), ErrorsLib.INCONSISTENT_INPUT);

        _accrueInterest(marketParams, marketId);

        {
            uint256 collateralPrice = _getCollateralPrice(marketParams);

            require(!_isHealthy(marketParams, marketId, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);

            // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
            uint256 liquidationIncentiveFactor = UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR,
                WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
            );

            if (seizedAssets > 0) {
                uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

                repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
                    market[marketId].totalBorrowAssets,
                    market[marketId].totalBorrowShares
                );
            } else {
                seizedAssets = repaidShares
                    .toAssetsDown(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares)
                    .wMulDown(liquidationIncentiveFactor)
                    .mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
            }
        }
        uint256 repaidAssets = repaidShares.toAssetsUp(
            market[marketId].totalBorrowAssets,
            market[marketId].totalBorrowShares
        );

        position[marketId][borrower].borrowShares -= repaidShares.toUint128();
        market[marketId].totalBorrowShares -= repaidShares.toUint128();
        market[marketId].totalBorrowAssets = UtilsLib
            .zeroFloorSub(market[marketId].totalBorrowAssets, repaidAssets)
            .toUint128();

        position[marketId][borrower].collateral -= seizedAssets.toUint128();

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (position[marketId][borrower].collateral == 0) {
            badDebtShares = position[marketId][borrower].borrowShares;
            badDebtAssets = UtilsLib.min(
                market[marketId].totalBorrowAssets,
                badDebtShares.toAssetsUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares)
            );

            market[marketId].totalBorrowAssets -= badDebtAssets.toUint128();
            market[marketId].totalSupplyAssets -= badDebtAssets.toUint128();
            market[marketId].totalBorrowShares -= badDebtShares.toUint128();
            position[marketId][borrower].borrowShares = 0;
        }

        // `repaidAssets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Liquidate(
            marketId,
            msg.sender,
            borrower,
            repaidAssets,
            repaidShares,
            seizedAssets,
            badDebtAssets,
            badDebtShares
        );

        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

        if (data.length > 0) ILending8LiquidateCallback(msg.sender).onLending8Liquidate(repaidAssets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    /* FLASH LOANS */

    /// @notice Flash loan: transfer assets to caller, then call onLending8FlashLoan; token must be returned to the contract by end of the call.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        emit EventsLib.FlashLoan(msg.sender, token, assets);
        IERC20(token).safeTransfer(msg.sender, assets);
        ILending8FlashLoanCallback(msg.sender).onLending8FlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* AUTHORIZATION */

    /// @notice Allow or revoke authorized address to manage msg.sender positions (withdraw, borrow, withdrawCollateral).
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /// @notice Set authorization via EIP-712 signature (so another address can manage positions on behalf of authorizer without tx from owner).
    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
        /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
        require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
        require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR, hashStruct));
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

        require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);

        emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender,
            authorization.authorizer,
            authorization.authorized,
            authorization.isAuthorized
        );
    }

    /// @dev Checks if msg.sender can manage onBehalf positions (user themselves or authorized address).
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* INTEREST MANAGEMENT */

    /// @notice Accrue interest on the market up to current time (update totalBorrowAssets/Supply, lastUpdate, and feeRecipient share when fee is non-zero).
    function accrueInterest(MarketParams memory marketParams) external {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        _accrueInterest(marketParams, marketId);
    }

    /// @dev Accrues interest on the market: fetches borrowRate from IRM, increases totalBorrowAssets and totalSupplyAssets by interest; when fee is non-zero, accrues fee in supply shares to feeRecipient. Updates lastUpdate.
    function _accrueInterest(MarketParams memory marketParams, Id marketId) internal {
        uint256 elapsed = block.timestamp - market[marketId].lastUpdate;
        if (elapsed == 0) return;

        if (marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[marketId]);
            uint256 interest = market[marketId].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            market[marketId].totalBorrowAssets += interest.toUint128();
            market[marketId].totalSupplyAssets += interest.toUint128();

            uint256 feeShares;
            if (market[marketId].fee != 0) {
                uint256 feeAmount = interest.wMulDown(market[marketId].fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already increased by the full interest (including the fee amount).
                feeShares = feeAmount.toSharesDown(
                    market[marketId].totalSupplyAssets - feeAmount,
                    market[marketId].totalSupplyShares
                );
                position[marketId][feeRecipient].supplyShares += feeShares;
                market[marketId].totalSupplyShares += feeShares.toUint128();
            }

            emit EventsLib.AccrueInterest(marketId, borrowRate, interest, feeShares);
        }

        // Safe "unchecked" cast.
        market[marketId].lastUpdate = uint128(block.timestamp);
    }

    /* HEALTH CHECK */

    /// @dev Checks position health: returns true when debt is zero; otherwise fetches collateral price from global oracle and calls overload with price.
    function _isHealthy(MarketParams memory marketParams, Id marketId, address borrower) internal view returns (bool) {
        if (position[marketId][borrower].borrowShares == 0) return true;

        uint256 collateralPrice = _getCollateralPrice(marketParams);

        return _isHealthy(marketParams, marketId, borrower, collateralPrice);
    }

    /// @dev Returns price of 1 raw collateral token in raw loan token units, scaled by 1e36.
    /// @dev Oracle prices are in priceDecimals (e.g. 8); conversion uses token decimals.
    function _getCollateralPrice(MarketParams memory marketParams) internal view returns (uint256) {
        uint256 collateralUsd = IOraclePrice(oracle).getPrice(marketParams.collateralToken).price;
        require(collateralUsd > 0, ErrorsLib.ZERO_ORACLE_PRICE);
        uint256 loanUsd = IOraclePrice(oracle).getPrice(marketParams.loanToken).price;
        require(loanUsd > 0, ErrorsLib.ZERO_ORACLE_PRICE);
        uint8 collateralDecimals = uint8(IERC20Metadata(marketParams.collateralToken).decimals());
        uint8 loanDecimals = uint8(IERC20Metadata(marketParams.loanToken).decimals());
        return (collateralUsd * ORACLE_PRICE_SCALE * (10 ** loanDecimals))
            / (loanUsd * (10 ** collateralDecimals));
    }


    function _borrowed(Id marketId, address borrower) internal view returns (uint256) {
        return uint256(position[marketId][borrower].borrowShares).toAssetsUp(
            market[marketId].totalBorrowAssets,
            market[marketId].totalBorrowShares
        );
    }

    function _maxBorrow(Id marketId, address borrower, uint256 collateralPrice, uint256 lltv) internal view returns (uint256) {
        return uint256(position[marketId][borrower].collateral)
            .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(lltv);
    }

    /// @dev Healthy position: (collateral * collateralPrice / ORACLE_PRICE_SCALE) * lltv >= current debt (borrowShares in assets). Rounding favors the protocol — max borrow is maxBorrow minus one.
    function _isHealthy(
        MarketParams memory marketParams,
        Id marketId,
        address borrower,
        uint256 collateralPrice
    ) internal view returns (bool) {
        uint256 maxBorrow = _maxBorrow(marketId, borrower, collateralPrice, marketParams.lltv);
        uint256 borrowed = _borrowed(marketId, borrower);
        return maxBorrow >= borrowed;
    }

    /// @notice Returns position health: isHealthy, maxBorrow (in loan assets), borrowed (in loan assets), lltv (WAD).
    function health(MarketParams memory marketParams, address borrower)
        external
        view
        returns (bool isHealthy, uint256 maxBorrow, uint256 borrowed, uint256 lltv)
    {
        Id marketId = marketParams.id();
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        uint256 collateralPrice = _getCollateralPrice(marketParams);
        maxBorrow = _maxBorrow(marketId, borrower, collateralPrice, marketParams.lltv);
        borrowed = _borrowed(marketId, borrower);
        lltv = marketParams.lltv;
        isHealthy = maxBorrow >= borrowed;
        return (isHealthy, maxBorrow, borrowed, lltv);
    }


    function maxWithdraw(Id marketId, address onBehalf) external view returns (uint256) {
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        uint256 supplyShares = position[marketId][onBehalf].supplyShares;
        if (supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets) =
            (market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares, market[marketId].totalBorrowAssets);

        uint256 userAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 availableLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;

        return userAssets < availableLiquidity ? userAssets : availableLiquidity;
    }



    function maxWithdrawCollateral(Id marketId, address onBehalf) external view returns (uint256) {
        require(market[marketId].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        MarketParams memory marketParams = idToMarketParams[marketId];
        uint256 collateral = position[marketId][onBehalf].collateral;
        uint256 borrowShares = position[marketId][onBehalf].borrowShares;

        if (borrowShares == 0) return collateral;

        uint256 borrowed = _accruedBorrowed(marketParams, marketId, onBehalf);
        uint256 collateralPrice = _getCollateralPrice(marketParams);
        uint256 minCollateral =
            borrowed.mulDivUp(ORACLE_PRICE_SCALE * WAD, collateralPrice * marketParams.lltv);

        return collateral > minCollateral ? collateral - minCollateral : 0;
    }

    /// @dev Returns borrowed amount as if interest had been accrued (for view functions).
    function _accruedBorrowed(MarketParams memory marketParams, Id marketId, address borrower)
        internal
        view
        returns (uint256)
    {
        uint256 borrowShares = position[marketId][borrower].borrowShares;
        if (borrowShares == 0) return 0;

        uint256 totalBorrowAssets = market[marketId].totalBorrowAssets;
        uint256 totalBorrowShares = market[marketId].totalBorrowShares;
        uint256 elapsed = block.timestamp - market[marketId].lastUpdate;

        if (elapsed != 0 && marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market[marketId]);
            uint256 interest =
                totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            totalBorrowAssets += interest;
        }

        return uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    /* STORAGE VIEW */

    /// @notice Read arbitrary storage slots of the contract (for offline integrations and debugging).
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots; ) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
