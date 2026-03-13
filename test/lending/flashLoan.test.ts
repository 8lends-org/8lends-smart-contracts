import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "ethers";
import * as fs from "fs";
import * as path from "path";

const SEPOLIA_CHAIN_ID = 11155111;

type SepoliaConfig = {
  FlashLiquidator: string;
  USDC: string;
  Lending8: string;
  WBTC: string;
  AdaptiveCurveIrm: string;
};

async function getSepoliaConfig(): Promise<SepoliaConfig> {
  const configPath = path.join(__dirname, "../../scripts/config/11155111-config.json");
  const raw = fs.readFileSync(configPath, "utf-8");
  const config = JSON.parse(raw);
  return {
    FlashLiquidator: config.FlashLiquidator,
    USDC: config.USDC,
    Lending8: config.Lending8,
    WBTC: config.WBTC,
    AdaptiveCurveIrm: config.AdaptiveCurveIrm,
  };
}

const LLTV_80 = (80n * 10n ** 18n) / 100n;

function buildMarketParams(config: SepoliaConfig): { loanToken: string; collateralToken: string; irm: string; lltv: bigint } {
  return {
    loanToken: config.USDC,
    collateralToken: config.WBTC,
    irm: config.AdaptiveCurveIrm,
    lltv: LLTV_80,
  };
}

describe("FlashLoan", function () {
 
  it("flashLiquidate: liquidate on Sepolia", async function () {
    const net = await ethers.provider.getNetwork();
    if (Number(net.chainId) !== SEPOLIA_CHAIN_ID) {
      this.skip();
      return;
    }
    const borrower = process.env.LIQUIDATABLE_BORROWER;
    if (!borrower) {
      console.log("Skip: set LIQUIDATABLE_BORROWER to run real liquidation");
      this.skip();
      return;
    }
    const config = await getSepoliaConfig();
    const [signer] = await ethers.getSigners();
    const lending8 = await ethers.getContractAt("Lending8", config.Lending8, signer);
    const marketParams = buildMarketParams(config);
    const marketId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "address", "uint256"],
        [marketParams.loanToken, marketParams.collateralToken, marketParams.irm, marketParams.lltv]
      )
    );

    const erc20Abi = ["function balanceOf(address) view returns (uint256)"];
    const usdc = new ethers.Contract(config.USDC, erc20Abi, ethers.provider);
    const market = await lending8.market(marketId);
    const position = await lending8.position(marketId, borrower);
    const borrowShares = position[1];
    if (borrowShares === 0n) {
      console.log("Step 0: Skip — position has zero borrow");
      this.skip();
      return;
    }
    let repaidShares = (borrowShares * 5n) / 100n;
    if (repaidShares === 0n) repaidShares = 1n;
    const totalBorrowAssets = market[2];
    const totalBorrowShares = market[3];
    const repaidAssets =
      totalBorrowShares === 0n ? 0n : (repaidShares * totalBorrowAssets + totalBorrowShares - 1n) / totalBorrowShares;

    console.log("Step 1: repaidShares", repaidShares.toString(), "repaidAssets", repaidAssets.toString());
    const poolBalance = await usdc.balanceOf(config.Lending8);
    console.log("Step 2: Lending8 USDC balance (pool)", poolBalance.toString());
    if (poolBalance < repaidAssets) {
      throw new Error(`Step 2 FAIL: pool has ${poolBalance}, need ${repaidAssets}. Not enough liquidity.`);
    }
    console.log("Step 2: OK — pool liquidity sufficient");

    // flashLiquidate requires 5 args: (marketParams, borrower, repaidShares, swapPath, minLoanTokenOut)
    // On Sepolia: path may be [WBTC, WETH, USDC] if no direct WBTC/USDC pool; set minLoanTokenOut lower for slippage if needed.
    const swapPath = [marketParams.collateralToken, marketParams.loanToken];
    const minLoanTokenOut = repaidAssets;
    console.log("Step 2b: swapPath", swapPath, "minLoanTokenOut", minLoanTokenOut.toString());

    const flashLiquidator = await ethers.getContractAt("FlashLiquidator", config.FlashLiquidator, signer);
    const routerSet = await flashLiquidator.swapRouter();
    console.log("Step 2c: FlashLiquidator.swapRouter set?", routerSet !== ethers.ZeroAddress, "address:", routerSet);
    if (routerSet === ethers.ZeroAddress) {
      throw new Error("Step 2c FAIL: setSwapRouter was not called on FlashLiquidator. Call setSwapRouter(uniswapV2Router) first.");
    }

    console.log("Step 3: calling flashLiquidate(marketParams, borrower, repaidShares, swapPath, minLoanTokenOut)...");
    try {
      const tx = await flashLiquidator.flashLiquidate(marketParams, borrower, repaidShares, swapPath, minLoanTokenOut);
      console.log("Step 3: OK — Liquidation tx:", tx.hash);
      await tx.wait();
      expect(tx.hash).to.match(/^0x[a-fA-F0-9]{64}$/);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.log("Step 3 FAIL: error message:", msg);
      throw err;
    }
  });
});
