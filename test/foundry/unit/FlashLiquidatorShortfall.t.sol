// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../contracts/lending/FlashLiquidator.sol";
import { Lending8 } from "../../../contracts/lending/Lending8.sol";
import "../../../contracts/lending/interfaces/ILending8.sol";
import "../../../contracts/lending/interfaces/IOraclePrice.sol";
import "../../../contracts/lending/lib/MarketParamsLib.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Minimal mintable ERC20 (18 decimals in these tests) for real token flows.
contract MintableERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Oracle mock returning a per-token USD price (8 decimals).
contract MockOracle {
    mapping(address => uint256) public priceOf;

    function setPrice(address token, uint256 price) external {
        priceOf[token] = price;
    }

    function priceDecimals() external pure returns (uint8) {
        return 8;
    }

    function getPrice(address token) external view returns (IOraclePrice.PriceResult memory r) {
        r.price = priceOf[token];
    }
}

/// @notice Factory mock returning a configured pair address for a token couple.
contract MockV2Factory {
    mapping(bytes32 => address) internal pairs;

    function setPair(address a, address b, address pair) external {
        pairs[_key(a, b)] = pair;
        pairs[_key(b, a)] = pair;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[_key(a, b)];
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }
}

/// @notice Router mock swapping at oracle prices scaled by a configurable factor.
/// @dev out = amountIn * inUsd * rateWad / (outUsd * 1e18); assumes both tokens have 18 decimals.
///      Respects amountOutMin like the real Uniswap V2 router (reverts when out < min).
contract MockOracleRateRouter {
    address public factory;
    MockOracle public oracle;
    /// @dev 1e18 == exactly oracle price; 0.97e18 == 3% worse than oracle, etc.
    uint256 public rateWad = 1e18;

    constructor(address _factory, MockOracle _oracle) {
        factory = _factory;
        oracle = _oracle;
    }

    function setRate(uint256 _rateWad) external {
        rateWad = _rateWad;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        MintableERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 inUsd = oracle.priceOf(path[0]);
        uint256 outUsd = oracle.priceOf(path[1]);
        uint256 out = (amountIn * inUsd * rateWad) / (outUsd * 1e18);
        require(out >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        MintableERC20(path[1]).mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// @notice Economics of the flash branch against the REAL Lending8:
///         swap proceeds are floored at repaid * LIF * (1 - maxSlippage), so a shortfall
///         (proceeds < repaid, eating the liquidator's own balance) is possible iff
///         LIF * (1 - maxSlippage) < 1, i.e. maxSlippage > CURSOR * (1 - LLTV).
///         With the default 3% slippage: impossible at LLTV = 0.8, possible at LLTV = 0.95.
contract FlashLiquidatorShortfallTest is Test {
    uint256 internal constant WAD_ = 1e18;
    uint256 internal constant CURSOR = 0.3e18; // LIQUIDATION_CURSOR
    uint256 internal constant MAX_LIF = 1.15e18; // MAX_LIQUIDATION_INCENTIVE_FACTOR

    Lending8 public lending;
    FlashLiquidator public liq;
    MockOracle public oracle;
    MockV2Factory public factory;
    MockOracleRateRouter public router;
    MintableERC20 public loan;
    MintableERC20 public collateral;

    address public ownerAddr;
    address public supplierAddr;
    address public borrowerAddr;

    MarketParams public mp;

    function setUp() public {
        ownerAddr = makeAddr("owner");
        supplierAddr = makeAddr("supplier");
        borrowerAddr = makeAddr("borrower");

        vm.warp(1_700_000_000);

        loan = new MintableERC20("Loan", "LOAN", 18);
        collateral = new MintableERC20("Collateral", "COLL", 18);
        oracle = new MockOracle();
        oracle.setPrice(address(loan), 1e8); // $1
        oracle.setPrice(address(collateral), 1e8); // $1

        factory = new MockV2Factory();
        router = new MockOracleRateRouter(address(factory), oracle);
        factory.setPair(address(loan), address(collateral), makeAddr("pair"));

        // Real Lending8 behind a UUPS/ERC1967 proxy.
        vm.startPrank(ownerAddr);
        {
            Lending8 impl = new Lending8();
            bytes memory initData = abi.encodeCall(Lending8.initialize, (ownerAddr));
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            lending = Lending8(address(proxy));
        }
        lending.setOracle(address(oracle));
        lending.enableIrm(address(0)); // zero-interest markets

        // Real FlashLiquidator behind an ERC1967 proxy (initialize sets maxSlippage = 0.03e18).
        {
            FlashLiquidator impl = new FlashLiquidator();
            bytes memory initData = abi.encodeCall(
                FlashLiquidator.initialize,
                (ILending8(address(lending)), ownerAddr, address(router))
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            liq = FlashLiquidator(address(proxy));
        }
        vm.stopPrank();

        assertEq(liq.maxSlippage(), 0.03e18);
    }

    /* ─────────────────────────── helpers ─────────────────────────── */

    /// @dev Enables `lltv`, creates the market, supplies 100_000e18 loan liquidity, has the borrower
    ///      post 1000e18 collateral and borrow the max, then drops the collateral price to $0.9
    ///      so the position turns unhealthy.
    function _openUnhealthyMarket(uint256 lltv) internal {
        vm.startPrank(ownerAddr);
        lending.enableLltv(lltv);
        mp = MarketParams({
            loanToken: address(loan),
            collateralToken: address(collateral),
            irm: address(0),
            lltv: lltv
        });
        lending.createMarket(mp);
        vm.stopPrank();

        // Supplier provides flash/borrow liquidity.
        loan.mint(supplierAddr, 100_000e18);
        vm.startPrank(supplierAddr);
        loan.approve(address(lending), type(uint256).max);
        lending.supply(mp, 100_000e18, 0, supplierAddr, "");
        vm.stopPrank();

        // Borrower posts 1000e18 collateral ($1) and borrows the max for this LLTV.
        uint256 collateralAmount = 1000e18;
        uint256 maxBorrow = (collateralAmount * lltv) / WAD_;
        collateral.mint(borrowerAddr, collateralAmount);
        vm.startPrank(borrowerAddr);
        collateral.approve(address(lending), type(uint256).max);
        lending.supplyCollateral(mp, collateralAmount, borrowerAddr, "");
        lending.borrow(mp, maxBorrow, 0, borrowerAddr, borrowerAddr);
        vm.stopPrank();

        // Price drop AFTER borrowing -> position unhealthy.
        oracle.setPrice(address(collateral), 0.9e8);
        (bool healthy, , , ) = lending.health(mp, borrowerAddr);
        assertFalse(healthy, "position must be unhealthy before liquidation");
    }

    function _marketId() internal view returns (Id) {
        return MarketParamsLib.id(mp);
    }

    /// @dev LIF = min(MAX_LIF, WAD / (1 - CURSOR * (1 - lltv))), with Lending8's floor rounding.
    function _lif(uint256 lltv) internal pure returns (uint256) {
        uint256 denom = WAD_ - (CURSOR * (WAD_ - lltv)) / WAD_;
        uint256 lif = (WAD_ * WAD_) / denom;
        return lif < MAX_LIF ? lif : MAX_LIF;
    }

    struct Snap {
        uint256 liqLoan;
        uint256 liqColl;
        uint256 borrowerCollateral;
        uint128 totalBorrowAssets;
    }

    function _snap() internal view returns (Snap memory s) {
        s.liqLoan = loan.balanceOf(address(liq));
        s.liqColl = collateral.balanceOf(address(liq));
        (, , uint128 posCollateral) = lending.position(_marketId(), borrowerAddr);
        s.borrowerCollateral = posCollateral;
        (, , uint128 totalBorrowAssets, , , ) = lending.market(_marketId());
        s.totalBorrowAssets = totalBorrowAssets;
    }

    /// @dev repaid = drop in market debt (irm = 0, so no interest noise); seized = borrower collateral drop.
    function _measure(Snap memory before)
        internal
        view
        returns (uint256 repaid, uint256 seized, int256 loanDelta)
    {
        Snap memory a = _snap();
        repaid = uint256(before.totalBorrowAssets) - uint256(a.totalBorrowAssets);
        seized = before.borrowerCollateral - a.borrowerCollateral;
        loanDelta = int256(a.liqLoan) - int256(before.liqLoan);
    }

    /* ─────────────────────────── tests ─────────────────────────── */

    /// 1. LLTV = 0.8, router at the worst rate still allowed by minOut (0.97 of oracle):
    ///    LIF(0.8) ~ 1.06383 > 1/0.97, so proceeds > repaid even at max allowed slippage.
    ///    The flash repayment never dips into the liquidator's own balance.
    function test_lltv80_worstAllowedRate_noShortfall() public {
        _openUnhealthyMarket(0.8e18);
        router.setRate(0.97e18); // exactly minOut

        loan.mint(address(liq), 10e18); // small own buffer, must not be consumed
        Snap memory before = _snap();

        liq.liquidate(_marketId(), borrowerAddr, 200e18);

        (uint256 repaid, uint256 seized, int256 loanDelta) = _measure(before);
        // All collateral was swapped in the flash branch.
        assertEq(collateral.balanceOf(address(liq)), 0, "collateral fully swapped");
        assertLe(seized, 1000e18, "cannot seize more than posted");

        // Flash in/out nets to zero, so ownDelta = proceeds - repaid.
        int256 proceeds = loanDelta + int256(repaid);
        emit log_named_uint("repaid", repaid);
        emit log_named_uint("seized", seized);
        emit log_named_int("swap proceeds", proceeds);
        emit log_named_int("own balance delta", loanDelta);

        assertGt(loanDelta, 0, "no shortfall at LLTV=0.8 even at worst allowed rate");

        // delta ~ repaid * (LIF * 0.97 - 1)
        uint256 lif = _lif(0.8e18); // ~1.063829787e18
        int256 expected = int256((repaid * lif) / WAD_ * 0.97e18 / WAD_) - int256(repaid);
        assertApproxEqAbs(loanDelta, expected, 0.05e18, "delta ~ repaid*(LIF*0.97 - 1)");
    }

    /// 2. LLTV = 0.8, router 1% below minOut: flash swap reverts on amountOutMin ->
    ///    fallback direct liquidation from the own balance, seized collateral retained.
    function test_lltv80_rateBelowMinOut_fallbackDirect_keepsCollateral() public {
        _openUnhealthyMarket(0.8e18);
        router.setRate(0.96e18); // below the 0.97 floor -> swap always reverts

        loan.mint(address(liq), 300e18);
        Snap memory before = _snap();

        liq.liquidate(_marketId(), borrowerAddr, 200e18);

        (uint256 repaid, uint256 seized, int256 loanDelta) = _measure(before);
        emit log_named_uint("repaid", repaid);
        emit log_named_uint("seized", seized);
        emit log_named_int("own balance delta", loanDelta);

        // Direct branch paid from own funds; collateral could not be swapped and is retained.
        assertEq(loanDelta, -int256(repaid), "own balance decreased by repaid");
        assertGt(collateral.balanceOf(address(liq)), 0, "seized collateral retained");
        assertEq(collateral.balanceOf(address(liq)), seized, "all seized collateral kept");
    }

    /// 3. LLTV = 0.95, router at 0.97 of oracle (allowed by minOut):
    ///    LIF(0.95) ~ 1.01523 < 1/0.97 ~ 1.03093, so proceeds < repaid and the flash
    ///    repayment is topped up from the liquidator's own balance -> guaranteed loss.
    function test_lltv95_worstAllowedRate_shortfallEatsOwnBalance() public {
        _openUnhealthyMarket(0.95e18);
        router.setRate(0.97e18);

        loan.mint(address(liq), 50e18); // own buffer that gets partially consumed
        Snap memory before = _snap();

        liq.liquidate(_marketId(), borrowerAddr, 200e18);

        (uint256 repaid, uint256 seized, int256 loanDelta) = _measure(before);
        assertEq(collateral.balanceOf(address(liq)), 0, "collateral fully swapped");
        assertLe(seized, 1000e18, "cannot seize more than posted");

        int256 proceeds = loanDelta + int256(repaid);
        emit log_named_uint("repaid", repaid);
        emit log_named_uint("seized", seized);
        emit log_named_int("swap proceeds", proceeds);
        emit log_named_int("own balance delta", loanDelta);

        assertLt(loanDelta, 0, "shortfall: flash repayment ate own balance at LLTV=0.95");
        assertLt(proceeds, int256(repaid), "proceeds < repaid");

        // delta ~ -repaid * (1 - LIF * 0.97), LIF ~ 1.015228e18 -> ~ -3.0457e18 for repaid=200e18
        uint256 lif = _lif(0.95e18);
        int256 expected = int256((repaid * lif) / WAD_ * 0.97e18 / WAD_) - int256(repaid);
        assertApproxEqAbs(loanDelta, expected, 0.05e18, "delta ~ repaid*(LIF*0.97 - 1) < 0");
    }

    /// 4. LLTV = 0.95, router at 0.97, ZERO own balance: the flash branch cannot cover the
    ///    gap (proceeds < flash amount), reverts inside the callback, and the fallback has
    ///    no own funds either -> "FlashLiq: no funds available".
    function test_lltv95_zeroOwnBalance_reverts() public {
        _openUnhealthyMarket(0.95e18);
        router.setRate(0.97e18);

        assertEq(loan.balanceOf(address(liq)), 0);

        vm.expectRevert("FlashLiq: no funds available");
        liq.liquidate(_marketId(), borrowerAddr, 200e18);
    }

    /// 5. Boundary LLTV = 0.9: LIF = 1/0.97, so LIF * 0.97 ~ 1 exactly (maxSlippage == CURSOR*(1-LLTV)).
    ///    Delta is ~0 up to wei rounding; record the sign.
    function test_lltv90_boundary_deltaNearZero() public {
        _openUnhealthyMarket(0.9e18);
        router.setRate(0.97e18);

        loan.mint(address(liq), 10e18);
        Snap memory before = _snap();

        liq.liquidate(_marketId(), borrowerAddr, 200e18);

        (uint256 repaid, uint256 seized, int256 loanDelta) = _measure(before);
        int256 proceeds = loanDelta + int256(repaid);
        emit log_named_uint("repaid", repaid);
        emit log_named_uint("seized", seized);
        emit log_named_int("swap proceeds", proceeds);
        emit log_named_int("own balance delta (boundary)", loanDelta);

        assertApproxEqAbs(loanDelta, int256(0), 1e12, "boundary delta ~ 0 (wei rounding only)");
    }
}
