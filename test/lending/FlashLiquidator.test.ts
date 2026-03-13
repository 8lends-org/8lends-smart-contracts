import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { formatUnits, parseUnits } from "ethers";
import {
  FixedRateIrm,
  FlashLiquidator,
  Lending8,
  MockOracle,
  MockUniswapV2Router,
  USDC,
  WBTC,
} from "../../typechain-types";

const WAD = 10n ** 18n;
const PRICE_DECIMALS = 8;
const VIRTUAL_SHARES = 1_000_000n;
const VIRTUAL_ASSETS = 1n;

const WBTC_PRICE_USD = 67_000n * 10n ** BigInt(PRICE_DECIMALS);
const USDC_PRICE_USD = 1n * 10n ** BigInt(PRICE_DECIMALS);
const LLTV_80 = (80n * WAD) / 100n;

const LOG = true;
function step(name: string, ...args: unknown[]) {
  if (LOG) console.log(`  [FlashLiquidator] ${name}`, ...args.map((a) => (typeof a === "bigint" ? a.toString() : a)));
}

type MarketParams = {
  loanToken: string;
  collateralToken: string;
  irm: string;
  lltv: bigint;
};

function buildMarketId(mp: MarketParams): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "uint256"],
      [mp.loanToken, mp.collateralToken, mp.irm, mp.lltv]
    )
  );
}

function toAssetsUp(shares: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  if (totalShares === 0n) return 0n;
  return (shares * (totalAssets + VIRTUAL_ASSETS) + totalShares + VIRTUAL_SHARES - 1n) / (totalShares + VIRTUAL_SHARES);
}

async function deployFlashLiquidatorFixture(): Promise<{
  lending8: Lending8;
  flashLiquidator: FlashLiquidator;
  mockRouter: MockUniswapV2Router;
  fixedRateIrm: FixedRateIrm;
  oracle: MockOracle;
  usdc: USDC;
  wbtc: WBTC;
  marketParams: MarketParams;
  owner: HardhatEthersSigner;
  supplier: HardhatEthersSigner;
  borrower: HardhatEthersSigner;
  liquidator: HardhatEthersSigner;
}> {
  const [owner, supplier, borrower, liquidator] = await ethers.getSigners();

  const Lending8Factory = await ethers.getContractFactory("Lending8", owner);
  const lending8Proxy = await upgrades.deployProxy(Lending8Factory, [owner.address], {
    kind: "uups",
    initializer: "initialize",
  });
  const lending8 = await ethers.getContractAt("Lending8", await lending8Proxy.getAddress()) as Lending8;

  const FixedRateIrmFactory = await ethers.getContractFactory("FixedRateIrm", owner);
  const fixedRateIrm = await FixedRateIrmFactory.deploy();

  const MockOracleFactory = await ethers.getContractFactory("MockOracle", owner);
  const oracle = await MockOracleFactory.deploy();

  const USDCFactory = await ethers.getContractFactory("USDC", owner);
  const usdcProxy = await upgrades.deployProxy(
    USDCFactory,
    [owner.address, "Test USDC", "USDC", 6],
    { kind: "uups", initializer: "initialize" }
  );
  const usdc = await ethers.getContractAt("USDC", await usdcProxy.getAddress()) as USDC;

  const WBTCFactory = await ethers.getContractFactory("WBTC", owner);
  const wbtcProxy = await upgrades.deployProxy(
    WBTCFactory,
    [owner.address, "Wrapped BTC", "WBTC", 8],
    { kind: "uups", initializer: "initialize" }
  );
  const wbtc = await ethers.getContractAt("WBTC", await wbtcProxy.getAddress()) as WBTC;

  await lending8.enableIrm(await fixedRateIrm.getAddress());
  await lending8.enableLltv(LLTV_80);
  await lending8.setOracle(await oracle.getAddress());
  await oracle.setPrice(await usdc.getAddress(), USDC_PRICE_USD);
  await oracle.setPrice(await wbtc.getAddress(), WBTC_PRICE_USD);

  const SECONDS_PER_YEAR = 365n * 24n * 3600n;
  const borrowRate = (5n * WAD) / 100n / SECONDS_PER_YEAR;
  const marketParams: MarketParams = {
    loanToken: await usdc.getAddress(),
    collateralToken: await wbtc.getAddress(),
    irm: await fixedRateIrm.getAddress(),
    lltv: LLTV_80,
  };
  await fixedRateIrm.setBorrowRate(buildMarketId(marketParams), borrowRate);
  await lending8.createMarket(marketParams);

  await usdc.connect(owner).transfer(await supplier.getAddress(), parseUnits("100000", 6));
  await wbtc.connect(owner).transfer(await borrower.getAddress(), parseUnits("1", 8));

  const FlashLiquidatorFactory = await ethers.getContractFactory("FlashLiquidator", owner);
  const flashLiquidatorProxy = await upgrades.deployProxy(
    FlashLiquidatorFactory,
    [await lending8.getAddress(), owner.address],
    { kind: "uups", initializer: "initialize" }
  );
  const flashLiquidator = await ethers.getContractAt("FlashLiquidator", await flashLiquidatorProxy.getAddress()) as FlashLiquidator;

  // WBTC (8 dec) -> USDC (6 dec): rate high so swap gives enough to repay flash (amountOut = amountIn * rateNum / rateDenom)
  const rateNum = 2000n * 10n ** 6n;
  const rateDenom = 1n;
  const mockRouter = await (await ethers.getContractFactory("MockUniswapV2Router", owner)).deploy(rateNum, rateDenom) as MockUniswapV2Router;
  await flashLiquidator.setSwapRouter(await mockRouter.getAddress());

  const routerUsdcReserve = parseUnits("150000000", 6);
  await usdc.connect(owner).transfer(await mockRouter.getAddress(), routerUsdcReserve);

  return {
    lending8,
    flashLiquidator,
    mockRouter,
    fixedRateIrm,
    oracle,
    usdc,
    wbtc,
    marketParams,
    owner,
    supplier,
    borrower,
    liquidator,
  };
}

describe("FlashLiquidator", function () {
  it("direct liquidate works (position becomes liquidatable after price drop)", async function () {
    const {
      lending8,
      oracle,
      usdc,
      wbtc,
      marketParams,
      supplier,
      borrower,
      liquidator,
    } = await loadFixture(deployFlashLiquidatorFixture);

    step("1.1 Supply USDC to pool", formatUnits(parseUnits("10000", 6), 6), "USDC");
    const supplyAmount = parseUnits("10000", 6);
    await usdc.connect(supplier).approve(await lending8.getAddress(), supplyAmount);
    await lending8.connect(supplier).supply(marketParams, supplyAmount, 0n, await supplier.getAddress(), "0x");

    step("1.2 Borrower supplies collateral (WBTC)");
    const collateralAmount = parseUnits("0.001", 8);
    await wbtc.connect(borrower).approve(await lending8.getAddress(), collateralAmount);
    await lending8.connect(borrower).supplyCollateral(marketParams, collateralAmount, borrower.address, "0x");

    step("1.3 Borrower borrows USDC");
    const borrowAmount = parseUnits("50", 6);
    await lending8.connect(borrower).borrow(marketParams, borrowAmount, 0n, borrower.address, borrower.address);

    step("1.4 Oracle: lower WBTC price so position becomes underwater");
    const newWbtcPrice = 40_000n * 10n ** BigInt(PRICE_DECIMALS);
    await oracle.setPrice(await wbtc.getAddress(), newWbtcPrice);

    step("1.5 Accrue interest and read market/position");
    await lending8.accrueInterest(marketParams);
    const marketId = buildMarketId(marketParams);
    const market = await lending8.market(marketId);
    const position = await lending8.position(marketId, borrower.address);
    const borrowerShares = position[1];
    const repaidShares = borrowerShares / 2n;
    const repaidAssets = toAssetsUp(repaidShares, market[2], market[3]);
    step("1.6 repaidShares", repaidShares, "repaidAssets (USDC)", repaidAssets);

    step("1.7 Liquidator pays USDC and calls liquidate (no flash)");
    await usdc.connect(supplier).transfer(liquidator.address, repaidAssets);
    await usdc.connect(liquidator).approve(await lending8.getAddress(), repaidAssets);
    const wbtcBefore = await wbtc.balanceOf(liquidator.address);
    await lending8
      .connect(liquidator)
      .liquidate(marketParams, borrower.address, 0, repaidShares, "0x");
    const wbtcAfter = await wbtc.balanceOf(liquidator.address);
    step("1.8 Liquidator received WBTC", wbtcAfter - wbtcBefore);
    expect(wbtcAfter - wbtcBefore).to.be.gt(0n);
  });

  it("full flow: supply -> borrow -> lower collateral price -> flashLiquidate", async function () {
    const {
      lending8,
      flashLiquidator,
      mockRouter,
      oracle,
      usdc,
      wbtc,
      marketParams,
      supplier,
      borrower,
      liquidator,
    } = await loadFixture(deployFlashLiquidatorFixture);

    // --- Setup: pool has liquidity ---
    step("2.1 Supply USDC to Lending8 pool");
    const supplyAmount = parseUnits("10000", 6);
    await usdc.connect(supplier).approve(await lending8.getAddress(), supplyAmount);
    await lending8
      .connect(supplier)
      .supply(marketParams, supplyAmount, 0n, await supplier.getAddress(), "0x");
    const poolUsdcAfterSupply = await usdc.balanceOf(await lending8.getAddress());
    step("2.1 Pool USDC after supply", poolUsdcAfterSupply.toString());

    step("2.2 Borrower supplies WBTC collateral");
    const collateralAmount = parseUnits("0.001", 8);
    await wbtc.connect(borrower).approve(await lending8.getAddress(), collateralAmount);
    await lending8.connect(borrower).supplyCollateral(marketParams, collateralAmount, borrower.address, "0x");

    step("2.3 Borrower borrows USDC");
    const borrowAmount = parseUnits("50", 6);
    await lending8.connect(borrower).borrow(marketParams, borrowAmount, 0n, borrower.address, borrower.address);

    const marketId = buildMarketId(marketParams);
    const positionBefore = await lending8.position(marketId, borrower.address);
    step("2.4 Borrower borrow shares", positionBefore[1].toString());
    expect(positionBefore[1]).to.be.gt(0n);

    // --- Make position liquidatable ---
    step("2.5 Oracle: set WBTC price down (position underwater)");
    const newWbtcPrice = 40_000n * 10n ** BigInt(PRICE_DECIMALS);
    await oracle.setPrice(await wbtc.getAddress(), newWbtcPrice);

    step("2.6 Accrue interest");
    await lending8.accrueInterest(marketParams);
    const market = await lending8.market(marketId);
    const totalBorrowAssets = market[2];
    const totalBorrowShares = market[3];
    const borrowerShares = positionBefore[1];

    const repaidShares = borrowerShares / 2n;
    expect(repaidShares).to.be.gt(0n);
    const repaidAssets = toAssetsUp(repaidShares, totalBorrowAssets, totalBorrowShares);
    step("2.7 repaidShares", repaidShares.toString(), "repaidAssets (USDC to repay)", repaidAssets.toString());

    // --- Flash liquidate: need swap path and minOut ---
    const swapPath = [marketParams.collateralToken, marketParams.loanToken];
    const minLoanTokenOut = repaidAssets;
    step("2.8 swapPath", swapPath, "minLoanTokenOut", minLoanTokenOut.toString());
    step("2.8 FlashLiquidator.swapRouter set?", (await flashLiquidator.swapRouter()) !== ethers.ZeroAddress);
    step("2.8 MockRouter USDC reserve (for swap out)", (await usdc.balanceOf(await mockRouter.getAddress())).toString());

    const lending8UsdcBefore = await usdc.balanceOf(await lending8.getAddress());
    step("2.9 Lending8 USDC before flashLiquidate", lending8UsdcBefore.toString());

    step("2.10 Call flashLiquidate(marketParams, borrower, repaidShares, swapPath, minLoanTokenOut)");
    await flashLiquidator
      .connect(liquidator)
      .flashLiquidate(marketParams, borrower.address, repaidShares, swapPath, minLoanTokenOut);

    const lending8UsdcAfter = await usdc.balanceOf(await lending8.getAddress());
    step("2.11 Lending8 USDC after", lending8UsdcAfter.toString(), "expected +repaidAssets", (lending8UsdcBefore + repaidAssets).toString());
    expect(lending8UsdcAfter).to.equal(lending8UsdcBefore + repaidAssets);

    const positionAfter = await lending8.position(marketId, borrower.address);
    step("2.12 Borrower shares after", positionAfter[1].toString(), "before", borrowerShares.toString());
    expect(positionAfter[1]).to.lt(borrowerShares);
  });

  /**
   * Почему на Sepolia может не работать (чек-лист для отладки):
   * 1. flashLiquidate принимает 5 аргументов: marketParams, borrower, repaidShares, swapPath, minLoanTokenOut.
   *    Без swapPath и minLoanTokenOut вызов не скомпилируется / реверт.
   * 2. setSwapRouter(router) должен быть вызван (на Sepolia — адрес реального Uniswap V2 Router).
   * 3. swapPath: первый = collateralToken (WBTC), последний = loanToken (USDC). На Sepolia может быть [WBTC, WETH, USDC].
   * 4. minLoanTokenOut >= repaidAssets. На реальном DEX если своп даёт меньше — revert (slippage).
   * 5. В пуле Uniswap должна быть ликвидность по пути, курс даёт >= minLoanTokenOut за seized collateral.
   * 6. Позиция должна быть ликвидируемой (health factor < 1 после accrueInterest).
   */
  it("checklist: swapRouter set; flashLiquidate expects 5 args (reverts if path invalid)", async function () {
    const { flashLiquidator, marketParams, borrower } = await loadFixture(deployFlashLiquidatorFixture);
    step("3.1 swapRouter must be set");
    expect(await flashLiquidator.swapRouter()).to.not.equal(ethers.ZeroAddress);
    step("3.2 Call with wrong path length reverts");
    await expect(
      flashLiquidator.flashLiquidate(marketParams, borrower.address, 1n, [], 1n)
    ).to.be.revertedWith("invalid path");
    step("3.3 Call with wrong path endpoints reverts");
    const wrongPath = [marketParams.loanToken, marketParams.collateralToken];
    await expect(
      flashLiquidator.flashLiquidate(marketParams, borrower.address, 1n, wrongPath, 1n)
    ).to.be.revertedWith("path endpoints");
  });
});
