/**
 * FlashLiquidator + Lending8 на форке Sepolia.
 *
 * Запуск: FORK_SEPOLIA=1 npx hardhat test test/lending/FlashLiquidatorSepoliaFork.test.ts --network hardhat
 *
 * Параметры ликвидации заданы ниже (или через env SEPOLIA_FORK_*).
 * Форк идёт с latest; для старого блока нужен archive RPC.
 */

import { expect } from "chai";
import { ethers, network, upgrades } from "hardhat";
import { parseUnits } from "ethers";
import * as fs from "fs/promises";
import * as path from "path";

const WAD = 10n ** 18n;
const PRICE_DECIMALS = 8;
const LLTV_80 = (80n * WAD) / 100n;

/** На форке даём подписанту ETH на газ (нужно > max upfront cost ~3 ETH). */
async function fundSignerOnFork(signerAddress: string): Promise<void> {
  await network.provider?.send("hardhat_setBalance", [
    signerAddress,
    "0x" + (10n * 10n ** 18n).toString(16),
  ]);
}

const SEPOLIA_CHAIN_ID = 11155111;

function getConfigPath(): string {
  return path.join(process.cwd(), "scripts", "config", `${SEPOLIA_CHAIN_ID}-config.json`);
}

async function loadSepoliaConfig(): Promise<Record<string, string>> {
  const configPath = getConfigPath();
  try {
    const data = await fs.readFile(configPath, "utf8");
    return JSON.parse(data);
  } catch (e) {
    throw new Error(`Failed to load config from ${configPath}: ${e}`);
  }
}

function formatRevert(err: unknown): string {
  const e = err as { message?: string; shortMessage?: string; reason?: string; data?: string; stack?: string; code?: string };
  const parts: string[] = [];
  if (e.shortMessage) parts.push(`shortMessage: ${e.shortMessage}`);
  if (e.reason) parts.push(`reason: ${e.reason}`);
  if (e.message) parts.push(`message: ${e.message}`);
  if (e.code) parts.push(`code: ${e.code}`);
  if (e.data) parts.push(`data: ${e.data}`);
  if (e.stack) parts.push(`stack: ${e.stack}`);
  return parts.length > 0 ? parts.join("\n") : String(err);
}

/** Из стека вытаскивает строки с "at ... (file.sol:line)" — это места вызова снизу вверх. */
function decodeRevertLocation(err: unknown): string {
  const e = err as { stack?: string; message?: string };
  const stack = e.stack ?? e.message ?? "";
  const lines = stack.split("\n").filter((s) => /\.sol:\d+\)/.test(s) || /at \S+ \(/.test(s));
  const locations = lines
    .map((s) => s.trim())
    .filter((s) => s.startsWith("at "))
    .slice(0, 8);
  if (locations.length === 0) return "";
  return "Цепочка вызовов (снизу вверх):\n  " + locations.join("\n  ");
}

/**
 * Расшифровка реверта без исходников внешних контрактов.
 * Подставляет имена Lending8/FlashLiquidator по адресам и даёт короткое пояснение.
 */
function decodeRevertSummary(
  err: unknown,
  config?: { Lending8?: string; FlashLiquidator?: string },
): string {
  const e = err as { message?: string; reason?: string; stack?: string };
  const msg = e.reason ?? e.message ?? "";
  const stack = e.stack ?? "";
  const lending8Addr = config?.Lending8?.toLowerCase();
  const flashLiqAddr = config?.FlashLiquidator?.toLowerCase();

  const lines: string[] = [];
  if (msg.includes("transferFrom reverted")) {
    lines.push("Реверт внутри контракта Lending8 при вызове liquidate(): не прошёл transferFrom (списание loan token с ликвидатора).");
    lines.push("Точное место: Lending8.sol, строка 479 — IERC20(loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets).");
    lines.push("Наш вызов: FlashLiquidator.sol, строка 80 — LENDING8.liquidate(...).");
  } else if (msg) {
    lines.push(`Причина: ${msg}`);
  }

  const ourCalls = stack.match(/FlashLiquidator\.\w+ \(contracts\/lending\/FlashLiquidator\.sol:(\d+)\)/g);
  if (ourCalls?.length) {
    lines.push("Наши строки в стеке: " + ourCalls.join(" → "));
  }

  if (lending8Addr && flashLiqAddr) {
    const escaped = (a: string) => a.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    let replaced = stack;
    replaced = replaced.replace(new RegExp(escaped(lending8Addr), "g"), "Lending8");
    replaced = replaced.replace(new RegExp(escaped(flashLiqAddr), "g"), "FlashLiquidator");
    const atLines = replaced.split("\n").filter((s) => s.trim().startsWith("at ")).slice(0, 8);
    if (atLines.length) {
      lines.push("Цепочка (адреса заменены на имена):");
      atLines.forEach((l) => lines.push("  " + l.trim()));
    }
  }
  return lines.join("\n");
}

function buildMarketId(marketParams: { loanToken: string; collateralToken: string; irm: string; lltv: bigint }): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "address", "uint256"],
      [marketParams.loanToken, marketParams.collateralToken, marketParams.irm, marketParams.lltv],
    ),
  );
}

/** Параметры ликвидации для форка Sepolia (замените на актуальные или задайте через env). */
const DEFAULT_SEPOLIA_FORK_MARKET_ID = process.env.SEPOLIA_FORK_MARKET_ID ?? "0x5d6f21c4668d59edf1c7399a5d40634473bfd6366a82e37dd52efd2a8b594892";
const DEFAULT_SEPOLIA_FORK_BORROWER = process.env.SEPOLIA_FORK_BORROWER ?? "0x2A911F55B4F940422046B4Ebf3D64bbaC38AB599";
const DEFAULT_SEPOLIA_FORK_REPAID_ASSETS = process.env.SEPOLIA_FORK_REPAID_ASSETS ?? "1000000";

describe("FlashLiquidator + Lending8 (Sepolia fork)", function () {
  const forkEnabled = process.env.FORK_SEPOLIA === "1";
  const marketId = DEFAULT_SEPOLIA_FORK_MARKET_ID;
  const borrower = DEFAULT_SEPOLIA_FORK_BORROWER;
  const repaidAssetsStr = DEFAULT_SEPOLIA_FORK_REPAID_ASSETS;

  before(function () {
    if (!forkEnabled) {
      this.skip();
      return;
    }
    if (!process.env.ETHEREUM_SEPOLIA_RPC_URL && !process.env.FORK_SEPOLIA) {
      console.warn("ETHEREUM_SEPOLIA_RPC_URL not set, fork may use public RPC");
    }
  });

  it("loads config and connects to FlashLiquidator and Lending8", async function () {
    if (!forkEnabled) this.skip();
    const config = await loadSepoliaConfig();
    expect(config.Lending8).to.be.a("string");
    expect(config.FlashLiquidator).to.be.a("string");
    expect(config.uniswapV2Router).to.be.a("string");

    const lending8 = await ethers.getContractAt("Lending8", config.Lending8);
    const flashLiq = await ethers.getContractAt("FlashLiquidator", config.FlashLiquidator);

    expect(await lending8.getAddress()).to.equal(config.Lending8);
    try {
      expect(await flashLiq.LENDING8()).to.equal(config.Lending8);
      expect(await flashLiq.uniswapV2Router()).to.equal(config.uniswapV2Router);
    } catch (e) {
      console.warn("  FlashLiquidator view failed (proxy/ABI?), config addresses used:", (e as Error).message);
    }
  });

  it("runs liquidation and prints revert location on failure", async function () {
    if (!forkEnabled) this.skip();

    const config = await loadSepoliaConfig();
    const repaidAssets = BigInt(repaidAssetsStr);

    const [signer] = await ethers.getSigners();
    await fundSignerOnFork(await signer.getAddress());

    const flashLiq = await ethers.getContractAt("FlashLiquidator", config.FlashLiquidator, signer);

    console.log("\n  Lending8:", config.Lending8);
    console.log("  FlashLiquidator:", config.FlashLiquidator);
    console.log("  marketId:", marketId);
    console.log("  borrower:", borrower);
    console.log("  repaidAssets (wei):", repaidAssets.toString());
    console.log("  caller:", await signer.getAddress());

    try {
      const tx = await flashLiq.liquidate(marketId as `0x${string}`, borrower, repaidAssets);
      const receipt = await tx.wait();
      expect(receipt?.status).to.equal(1);
      console.log("\n  Tx hash:", receipt?.hash);
      console.log("  Status: success");
    } catch (err: unknown) {
      const summary = decodeRevertSummary(err, config);
      console.error("\n  === REVERT (расшифровка) ===\n", summary);
      console.error("\n  === REVERT (сырой вывод) ===\n", formatRevert(err));
      throw err;
    }
  });

  it("optional: staticCall liquidation to get revert without sending tx", async function () {
    if (!forkEnabled) this.skip();

    const config = await loadSepoliaConfig();
    const repaidAssets = BigInt(repaidAssetsStr);
    const [signer] = await ethers.getSigners();
    await fundSignerOnFork(await signer.getAddress());
    const flashLiq = await ethers.getContractAt("FlashLiquidator", config.FlashLiquidator, signer);

    try {
      await flashLiq.liquidate.staticCall(marketId as `0x${string}`, borrower, repaidAssets);
      console.log("\n  staticCall: would succeed");
    } catch (err: unknown) {
      const summary = decodeRevertSummary(err, config);
      console.error("\n  === staticCall REVERT (расшифровка) ===\n", summary);
      console.error("\n  === staticCall REVERT (сырой вывод) ===\n", formatRevert(err));
      throw err;
    }
  });
});

/**
 * Локальный деплой Lending8 и FlashLiquidator (без форка). В консоли будет Hardhat console.log
 * из Lending8: repaidAssets и allowance перед transferFrom.
 * Запуск: npx hardhat test test/lending/FlashLiquidatorSepoliaFork.test.ts --grep "local deploy"
 */
describe("FlashLiquidator + Lending8 (local deploy, see console.log)", function () {
  const forkEnabled = process.env.FORK_SEPOLIA === "1";
  this.timeout(60_000);

  before(function () {
    if (forkEnabled) this.skip();
  });

  it("local deploy Lending8 and FlashLiquidator, runs liquidation (see console.log)", async function () {
    if (forkEnabled) this.skip();

    const [owner, user] = await ethers.getSigners();

    const Lending8Factory = await ethers.getContractFactory("Lending8", owner);
    const lending8Proxy = await upgrades.deployProxy(Lending8Factory, [owner.address], {
      kind: "uups",
      initializer: "initialize",
    });
    const lending8 = await ethers.getContractAt("Lending8", await lending8Proxy.getAddress());

    const FixedRateIrmFactory = await ethers.getContractFactory("FixedRateIrm", owner);
    const fixedRateIrm = await FixedRateIrmFactory.deploy();

    const MockOracleFactory = await ethers.getContractFactory("MockOracle", owner);
    const oracle = await MockOracleFactory.deploy();

    const USDCFactory = await ethers.getContractFactory("USDC", owner);
    const usdcProxy = await upgrades.deployProxy(
      USDCFactory,
      [owner.address, "Test USDC", "USDC", 6],
      { kind: "uups", initializer: "initialize" },
    );
    const usdc = await ethers.getContractAt("USDC", await usdcProxy.getAddress());

    const WBTCFactory = await ethers.getContractFactory("WBTC", owner);
    const wbtcProxy = await upgrades.deployProxy(
      WBTCFactory,
      [owner.address, "Wrapped BTC", "WBTC", 8],
      { kind: "uups", initializer: "initialize" },
    );
    const wbtc = await ethers.getContractAt("WBTC", await wbtcProxy.getAddress());

    const usdcAddr = await usdc.getAddress();
    const wbtcAddr = await wbtc.getAddress();
    const irmAddr = await fixedRateIrm.getAddress();
    const oracleAddr = await oracle.getAddress();

    await lending8.enableIrm(irmAddr);
    await lending8.enableLltv(LLTV_80);
    await lending8.setOracle(oracleAddr);
    await oracle.setPrice(usdcAddr, 1n * 10n ** BigInt(PRICE_DECIMALS));
    const wbtcPriceHigh = 67_000n * 10n ** BigInt(PRICE_DECIMALS);
    await oracle.setPrice(wbtcAddr, wbtcPriceHigh);

    const SECONDS_PER_YEAR = 365n * 24n * 3600n;
    const borrowRate = (5n * WAD) / 100n / SECONDS_PER_YEAR;
    const marketParams = {
      loanToken: usdcAddr,
      collateralToken: wbtcAddr,
      irm: irmAddr,
      lltv: LLTV_80,
    };
    await fixedRateIrm.setBorrowRate(buildMarketId(marketParams), borrowRate);
    await lending8.createMarket(marketParams);

    const supplyAmount = parseUnits("100000", 6);
    await usdc.connect(owner).transfer(await user.getAddress(), supplyAmount);
    await wbtc.connect(owner).transfer(await user.getAddress(), parseUnits("1", 8));

    await usdc.connect(user).approve(await lending8.getAddress(), supplyAmount);
    await lending8.connect(user).supply(marketParams, parseUnits("10000", 6), 0n, user.address, "0x");

    const collateralAmount = parseUnits("0.001", 8);
    await wbtc.connect(user).approve(await lending8.getAddress(), collateralAmount);
    await lending8.connect(user).supplyCollateral(marketParams, collateralAmount, user.address, "0x");

    const borrowAmount = parseUnits("50", 6);
    await lending8.connect(user).borrow(marketParams, borrowAmount, 0n, user.address, user.address);

    const wbtcPriceLow = 40_000n * 10n ** BigInt(PRICE_DECIMALS);
    await oracle.setPrice(wbtcAddr, wbtcPriceLow);

    const MockRouterFactory = await ethers.getContractFactory("MockUniswapV2Router", owner);
    const rateNum = 10100000n;
    const rateDenom = 1000n;
    const mockRouter = await MockRouterFactory.deploy(rateNum, rateDenom);
    await usdc.connect(owner).transfer(await mockRouter.getAddress(), parseUnits("20000000", 6));

    const FlashLiquidatorFactory = await ethers.getContractFactory("FlashLiquidator", owner);
    const flashLiqProxy = await upgrades.deployProxy(
      FlashLiquidatorFactory,
      [await lending8.getAddress(), owner.address, await mockRouter.getAddress()],
      { kind: "uups", initializer: "initialize" },
    );
    const flashLiq = await ethers.getContractAt("FlashLiquidator", await flashLiqProxy.getAddress());

    const marketId = buildMarketId(marketParams) as `0x${string}`;
    const repaidAssets = parseUnits("10", 6);

    console.log("\n  === Lending8 + FlashLiquidator (local); running liquidation — ниже лог из Lending8 ===\n");
    const tx = await flashLiq.connect(owner).liquidate(marketId, user.address, repaidAssets);
    const receipt = await tx.wait();
    expect(receipt?.status).to.equal(1);
    console.log("\n  Tx hash:", receipt?.hash);
  });
});

/**
 * То же на форке Sepolia (нужен RPC без rate limit).
 * FORK_SEPOLIA=1 npx hardhat test test/lending/FlashLiquidatorSepoliaFork.test.ts --network hardhat --grep "deployed on fork"
 */
describe("FlashLiquidator + Lending8 (deployed on fork)", function () {
  const forkEnabled = process.env.FORK_SEPOLIA === "1";
  this.timeout(60_000);

  before(function () {
    if (!forkEnabled) this.skip();
  });

  it("deploys Lending8 and FlashLiquidator on fork, runs liquidation (see console.log)", async function () {
    if (!forkEnabled) this.skip();

    const [owner, user] = await ethers.getSigners();
    await fundSignerOnFork(await owner.getAddress());
    await fundSignerOnFork(await user.getAddress());

    const config = await loadSepoliaConfig();
    const router = config.uniswapV2Router ?? ethers.ZeroAddress;

    const Lending8Factory = await ethers.getContractFactory("Lending8", owner);
    const lending8Proxy = await upgrades.deployProxy(Lending8Factory, [owner.address], {
      kind: "uups",
      initializer: "initialize",
    });
    const lending8 = await ethers.getContractAt("Lending8", await lending8Proxy.getAddress());

    const FixedRateIrmFactory = await ethers.getContractFactory("FixedRateIrm", owner);
    const fixedRateIrm = await FixedRateIrmFactory.deploy();

    const MockOracleFactory = await ethers.getContractFactory("MockOracle", owner);
    const oracle = await MockOracleFactory.deploy();

    const USDCFactory = await ethers.getContractFactory("USDC", owner);
    const usdcProxy = await upgrades.deployProxy(
      USDCFactory,
      [owner.address, "Test USDC", "USDC", 6],
      { kind: "uups", initializer: "initialize" },
    );
    const usdc = await ethers.getContractAt("USDC", await usdcProxy.getAddress());

    const WBTCFactory = await ethers.getContractFactory("WBTC", owner);
    const wbtcProxy = await upgrades.deployProxy(
      WBTCFactory,
      [owner.address, "Wrapped BTC", "WBTC", 8],
      { kind: "uups", initializer: "initialize" },
    );
    const wbtc = await ethers.getContractAt("WBTC", await wbtcProxy.getAddress());

    const usdcAddr = await usdc.getAddress();
    const wbtcAddr = await wbtc.getAddress();
    const irmAddr = await fixedRateIrm.getAddress();
    const oracleAddr = await oracle.getAddress();

    await lending8.enableIrm(irmAddr);
    await lending8.enableLltv(LLTV_80);
    await lending8.setOracle(oracleAddr);
    await oracle.setPrice(usdcAddr, 1n * 10n ** BigInt(PRICE_DECIMALS));
    const wbtcPriceHigh = 67_000n * 10n ** BigInt(PRICE_DECIMALS);
    await oracle.setPrice(wbtcAddr, wbtcPriceHigh);

    const SECONDS_PER_YEAR = 365n * 24n * 3600n;
    const borrowRate = (5n * WAD) / 100n / SECONDS_PER_YEAR;
    const marketParams = {
      loanToken: usdcAddr,
      collateralToken: wbtcAddr,
      irm: irmAddr,
      lltv: LLTV_80,
    };
    await fixedRateIrm.setBorrowRate(buildMarketId(marketParams), borrowRate);
    await lending8.createMarket(marketParams);

    const supplyAmount = parseUnits("100000", 6);
    await usdc.connect(owner).transfer(await user.getAddress(), supplyAmount);
    await wbtc.connect(owner).transfer(await user.getAddress(), parseUnits("1", 8));

    await usdc.connect(user).approve(await lending8.getAddress(), supplyAmount);
    await lending8.connect(user).supply(marketParams, parseUnits("10000", 6), 0n, user.address, "0x");

    const collateralAmount = parseUnits("0.001", 8);
    await wbtc.connect(user).approve(await lending8.getAddress(), collateralAmount);
    await lending8.connect(user).supplyCollateral(marketParams, collateralAmount, user.address, "0x");

    const borrowAmount = parseUnits("50", 6);
    await lending8.connect(user).borrow(marketParams, borrowAmount, 0n, user.address, user.address);

    const wbtcPriceLow = 40_000n * 10n ** BigInt(PRICE_DECIMALS);
    await oracle.setPrice(wbtcAddr, wbtcPriceLow);

    const MockRouterFactory = await ethers.getContractFactory("MockUniswapV2Router", owner);
    const mockRouter = await MockRouterFactory.deploy(10n ** 18n, 10n ** 8n);
    await usdc.connect(owner).transfer(await mockRouter.getAddress(), parseUnits("1000000", 6));

    const FlashLiquidatorFactory = await ethers.getContractFactory("FlashLiquidator", owner);
    const flashLiqProxy = await upgrades.deployProxy(
      FlashLiquidatorFactory,
      [await lending8.getAddress(), owner.address, router === ethers.ZeroAddress ? await mockRouter.getAddress() : router],
      { kind: "uups", initializer: "initialize" },
    );
    const flashLiq = await ethers.getContractAt("FlashLiquidator", await flashLiqProxy.getAddress());

    const marketId = buildMarketId(marketParams) as `0x${string}`;
    const repaidAssets = parseUnits("10", 6);

    console.log("\n  === Lending8 + FlashLiquidator on fork; liquidation (Lending8 console.log below) ===\n");
    const tx = await flashLiq.connect(owner).liquidate(marketId, user.address, repaidAssets);
    const receipt = await tx.wait();
    expect(receipt?.status).to.equal(1);
    console.log("\n  Tx hash:", receipt?.hash);
  });
});
