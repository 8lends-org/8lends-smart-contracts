// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../contracts/lending/FlashLiquidator.sol";
import "../../../contracts/lending/interfaces/ILending8.sol";
import "../../../contracts/lending/interfaces/ILending8Callbacks.sol";
import "../../../contracts/lending/interfaces/IOraclePrice.sol";
import "../../../contracts/lending/lib/MarketParamsLib.sol";
import "../../../contracts/lending/lib/SharesMathLib.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Minimal mintable ERC20 for exercising real token flows in the flash/swap paths.
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

/// @notice Oracle mock returning a per-token USD price.
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

/// @notice Router mock that swaps tokenIn->tokenOut 1:1 by minting the output token to `to`.
contract MockV2Router {
    address public factory;
    /// @dev Simulates a broken/empty pair: every swap reverts (e.g. INSUFFICIENT_LIQUIDITY).
    bool public swapReverts;

    constructor(address _factory) {
        factory = _factory;
    }

    function setSwapReverts(bool _swapReverts) external {
        swapReverts = _swapReverts;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(!swapReverts, "MockRouter: reverted");
        // Pull input token from caller, mint output token 1:1 (>= amountOutMin).
        MintableERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn;
        require(out >= amountOutMin, "MockRouter: insufficient output");
        MintableERC20(path[1]).mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// @notice Rich Lending8 mock modelling pool liquidity, flash loans, collateral seizure and debt repayment.
contract MockLending8Rich {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint128 public totalBorrowAssets = 100_000e6;
    uint128 public totalBorrowShares = 100_000e6;
    /// @dev Borrow shares reported for any borrower via position(); defaults to the whole market debt.
    uint128 public borrowerBorrowShares = 100_000e6;

    address public oracle;
    MarketParams internal storedMarketParams;

    bool public liquidateCalled;
    address public lastLiquidatedBorrower;
    uint256 public lastRepaidShares;
    uint256 public lastFlashAssets;
    bytes public lastLiquidateData;

    constructor(address _oracle) {
        oracle = _oracle;
    }

    function setMarketState(uint128 _totalBorrowAssets, uint128 _totalBorrowShares) external {
        totalBorrowAssets = _totalBorrowAssets;
        totalBorrowShares = _totalBorrowShares;
    }

    function setBorrowerShares(uint128 _borrowerBorrowShares) external {
        borrowerBorrowShares = _borrowerBorrowShares;
    }

    function position(Id, address) external view returns (Position memory p) {
        p.borrowShares = borrowerBorrowShares;
    }

    function setMarketParams(MarketParams memory marketParams) external {
        storedMarketParams = marketParams;
    }

    function accrueInterest(MarketParams memory) external {}

    function market(Id marketId) external view returns (Market memory) {
        if (Id.unwrap(marketId) != Id.unwrap(MarketParamsLib.id(storedMarketParams))) {
            return Market(0, 0, 0, 0, 0, 0);
        }
        return Market({
            totalSupplyAssets: 1_000_000e6,
            totalSupplyShares: 1_000_000e6,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
    }

    function idToMarketParams(Id marketId) external view returns (MarketParams memory) {
        if (Id.unwrap(marketId) != Id.unwrap(MarketParamsLib.id(storedMarketParams))) {
            return MarketParams({ loanToken: address(0), collateralToken: address(0), irm: address(0), lltv: 0 });
        }
        return storedMarketParams;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        lastFlashAssets = assets;
        MintableERC20(token).transfer(msg.sender, assets);
        ILending8FlashLoanCallback(msg.sender).onLending8FlashLoan(assets, data);
        MintableERC20(token).transferFrom(msg.sender, address(this), assets);
    }

    /// @dev Seizes collateral worth the repaid debt (1:1, no bonus) and pulls the repaid loan assets.
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256) {
        liquidateCalled = true;
        lastLiquidatedBorrower = borrower;
        lastRepaidShares = repaidShares;
        lastLiquidateData = data;

        uint256 repaidAssets = repaidShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
        uint256 seizedAssets = repaidAssets;

        // Hand the seized collateral to the liquidator, then pull the repaid loan assets.
        MintableERC20(marketParams.collateralToken).mint(msg.sender, seizedAssets);
        MintableERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }
}

contract FlashLiquidatorHybridTest is Test {
    FlashLiquidator public liq;
    MockLending8Rich public lending;
    MockOracle public oracle;
    MockV2Factory public factory;
    MockV2Router public router;
    MintableERC20 public loan;
    MintableERC20 public collateral;

    address public ownerAddr;
    address public borrowerAddr;

    MarketParams public mp;

    function setUp() public {
        ownerAddr = makeAddr("owner");
        borrowerAddr = makeAddr("borrower");

        vm.startPrank(ownerAddr);
        loan = new MintableERC20("Loan", "LOAN", 18);
        collateral = new MintableERC20("Collateral", "COLL", 18);
        oracle = new MockOracle();
        oracle.setPrice(address(loan), 1e8);
        oracle.setPrice(address(collateral), 1e8);

        factory = new MockV2Factory();
        router = new MockV2Router(address(factory));

        lending = new MockLending8Rich(address(oracle));
        mp = MarketParams({
            loanToken: address(loan),
            collateralToken: address(collateral),
            irm: address(0),
            lltv: 800_000_000_000_000_000
        });
        lending.setMarketParams(mp);

        FlashLiquidator impl = new FlashLiquidator();
        bytes memory initData = abi.encodeCall(
            FlashLiquidator.initialize,
            (ILending8(address(lending)), ownerAddr, address(router))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        liq = FlashLiquidator(address(proxy));
        vm.stopPrank();
    }

    function _marketId() internal view returns (Id) {
        return MarketParamsLib.id(mp);
    }

    function _enablePair() internal {
        factory.setPair(address(loan), address(collateral), makeAddr("pair"));
    }

    function _seedPool(uint256 amount) internal {
        loan.mint(address(lending), amount);
    }

    function _seedLiquidator(uint256 amount) internal {
        loan.mint(address(liq), amount);
    }

    function _expectedShares(uint256 assets) internal pure returns (uint256) {
        return SharesMathLib.toSharesDown(assets, 100_000e6, 100_000e6);
    }

    // ── Hybrid: pool liquidity partial, own balance covers the rest ──────────

    function test_hybrid_flashPlusOwnBalance() public {
        _enablePair();
        _seedPool(4_000e6); // L
        _seedLiquidator(10_000e6); // F
        uint256 requested = 6_000e6; // L < requested <= L + F

        liq.liquidate(_marketId(), borrowerAddr, requested);

        assertTrue(lending.liquidateCalled());
        // Full requested amount is liquidated (not capped).
        assertEq(lending.lastRepaidShares(), _expectedShares(requested));
        // Only the available pool liquidity is flash-loaned; the rest comes from own balance.
        assertEq(lending.lastFlashAssets(), 4_000e6);
    }

    // ── Cap: requested exceeds pool liquidity + own balance ─────────────────

    function test_cap_partialLiquidationToAvailable() public {
        _enablePair();
        _seedPool(4_000e6); // L
        _seedLiquidator(1_000e6); // F -> available = 5_000e6
        uint256 requested = 9_000e6;

        liq.liquidate(_marketId(), borrowerAddr, requested);

        assertEq(lending.lastRepaidShares(), _expectedShares(5_000e6));
        assertEq(lending.lastFlashAssets(), 4_000e6); // min(L, capped)
    }

    // ── Pure flash: enough pool liquidity, own balance untouched ────────────

    function test_pureFlash_ownBalanceUntouched() public {
        _enablePair();
        _seedPool(10_000e6);
        uint256 requested = 6_000e6;

        liq.liquidate(_marketId(), borrowerAddr, requested);

        assertEq(lending.lastRepaidShares(), _expectedShares(requested));
        assertEq(lending.lastFlashAssets(), 6_000e6);
        assertEq(loan.balanceOf(address(liq)), 0); // no own funds used
    }

    // ── No pair: own balance only, partial allowed ──────────────────────────

    function test_noPair_ownBalancePartial() public {
        // no pair enabled -> flash unavailable
        _seedLiquidator(3_000e6);
        uint256 requested = 5_000e6; // exceeds own balance -> capped to 3_000e6

        liq.liquidate(_marketId(), borrowerAddr, requested);

        assertEq(lending.lastRepaidShares(), _expectedShares(3_000e6));
        assertEq(lending.lastFlashAssets(), 0); // no flash used
    }

    // ── Pair exists but pool empty: inline liquidation with swap ────────────

    function test_pairButEmptyPool_inlineWithSwap() public {
        _enablePair();
        // pool has zero liquidity
        _seedLiquidator(5_000e6);
        uint256 requested = 3_000e6;

        liq.liquidate(_marketId(), borrowerAddr, requested);

        assertEq(lending.lastRepaidShares(), _expectedShares(3_000e6));
        assertEq(lending.lastFlashAssets(), 0); // inline, no flash
        // Seized collateral was swapped back to loan (1:1), so own balance is restored.
        assertEq(loan.balanceOf(address(liq)), 5_000e6);
    }

    // ── No funds available at all: revert ───────────────────────────────────

    function test_revert_noFundsAvailable() public {
        // no pair, no own balance
        vm.expectRevert("FlashLiq: no funds available");
        liq.liquidate(_marketId(), borrowerAddr, 1_000e6);
    }

    function test_revert_slippageUnset_withPair() public {
        _enablePair();
        _seedPool(10_000e6);
        _seedLiquidator(1_000e6);
        vm.prank(ownerAddr);
        liq.setMaxSlippage(0);

        // Zero slippage makes every swap-based path unusable. The flash branch's failure is
        // swallowed by _tryFlashLiquidate's catch, but the direct fallback needs a minOut too and
        // that one propagates — so the call reverts rather than silently doing nothing.
        vm.expectRevert("FlashLiq: slippage not set");
        liq.liquidate(_marketId(), borrowerAddr, 1_000e6);
    }

    function test_routerUnset_treatedAsNoPair() public {
        _enablePair();
        _seedPool(10_000e6);
        vm.prank(ownerAddr);
        liq.setUniswapV2Router(address(0));

        // hasUniswapV2Pair returns false on an unset router without ever reaching the factory, so
        // the registered pair is ignored and the pool's liquidity is not counted as available.
        vm.expectRevert("FlashLiq: no funds available");
        liq.liquidate(_marketId(), borrowerAddr, 1_000e6);
    }

    // ── Cap: requested exceeds the borrower's actual debt ───────────────────

    function test_cap_toBorrowerDebt() public {
        _enablePair();
        _seedPool(10_000e6);
        lending.setBorrowerShares(2_000e6); // borrower owes far less than requested
        uint256 requested = 5_000e6;

        liq.liquidate(_marketId(), borrowerAddr, requested);

        // Liquidation is capped at the borrower's debt shares instead of reverting on underflow.
        assertEq(lending.lastRepaidShares(), 2_000e6);
        // Flash loan takes only what is needed to repay the capped shares.
        uint256 cappedAssets = SharesMathLib.toAssetsUp(2_000e6, 100_000e6, 100_000e6);
        assertEq(lending.lastFlashAssets(), cappedAssets);
    }

    function test_revert_borrowerNoDebt() public {
        _enablePair();
        _seedPool(10_000e6);
        lending.setBorrowerShares(0);

        vm.expectRevert("FlashLiq: no debt");
        liq.liquidate(_marketId(), borrowerAddr, 1_000e6);
    }

    // ── DoS resistance: broken/empty Uniswap pair must not block liquidation ─

    function test_brokenPairSwap_flashFallsBackToOwnBalance() public {
        _enablePair();
        router.setSwapReverts(true); // pair exists but every swap reverts (e.g. empty pair)
        _seedPool(10_000e6);
        _seedLiquidator(3_000e6);

        liq.liquidate(_marketId(), borrowerAddr, 5_000e6);

        // Flash branch failed on the swap -> fell back to direct liquidation from own balance.
        assertTrue(lending.liquidateCalled());
        assertEq(lending.lastRepaidShares(), _expectedShares(3_000e6));
        assertEq(lending.lastFlashAssets(), 0); // failed flash attempt was reverted
        // Seized collateral could not be swapped and is retained by the contract.
        uint256 repaid = SharesMathLib.toAssetsUp(_expectedShares(3_000e6), 100_000e6, 100_000e6);
        assertEq(collateral.balanceOf(address(liq)), repaid);
        assertEq(loan.balanceOf(address(liq)), 3_000e6 - repaid);
    }

    function test_brokenPairSwap_noOwnBalance_reverts() public {
        _enablePair();
        router.setSwapReverts(true);
        _seedPool(10_000e6);
        // no own balance -> fallback has nothing to liquidate with

        vm.expectRevert("FlashLiq: no funds available");
        liq.liquidate(_marketId(), borrowerAddr, 5_000e6);
    }

    function test_directSwapFails_keepsCollateral() public {
        _enablePair();
        router.setSwapReverts(true);
        // pool empty -> direct branch; swap fails -> collateral must be kept, not revert
        _seedLiquidator(5_000e6);

        liq.liquidate(_marketId(), borrowerAddr, 3_000e6);

        assertEq(lending.lastRepaidShares(), _expectedShares(3_000e6));
        assertEq(lending.lastFlashAssets(), 0);
        uint256 repaid = SharesMathLib.toAssetsUp(_expectedShares(3_000e6), 100_000e6, 100_000e6);
        assertEq(collateral.balanceOf(address(liq)), repaid);
        assertEq(loan.balanceOf(address(liq)), 5_000e6 - repaid);
    }

    // ── Lending8.liquidate must receive empty callback data ─────────────────

    function test_liquidate_passesEmptyCallbackData() public {
        _seedLiquidator(1_000e6);

        liq.liquidate(_marketId(), borrowerAddr, 1_000e6);

        // Empty data -> Lending8 skips the onLending8Liquidate callback entirely.
        assertEq(lending.lastLiquidateData().length, 0);
    }
}
