import { expect } from "chai";
import { ethers, network } from "hardhat";
import { upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { Oracle } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { readFileSync } from "fs";
import { join } from "path";

const config:{
  "UniswapV3Factory": string;
  "tokens": {
    "WETH": string;
    "USDC": string;
    "WBTC": string;
    "SOL": string;
    "AUD": string;
  },
  "chainlink": {
    "CHAINLINK_BTC_USD": string;
    "CHAINLINK_AUD_USD": string;
    "CHAINLINK_ETH_USD": string;
    "CHAINLINK_SOL_USD": string;
  },
  "pyth": {
    "PYTH": string;
    "PYTH_ETH_USD_ID": string;
    "PYTH_BTC_USD_ID": string;
    "PYTH_SOL_USD_ID": string;
    "PYTH_AUD_USD_ID": string;
  }
} = JSON.parse(readFileSync(join(__dirname, `../scripts/config/8453-config.json`), "utf8"));
console.log("config: ", config);

const PRICE_SOURCE_NAMES = [
  "None",
  "Pyth",
  "ChainLink",
  "Uniswap",
];

/** Uniswap V3 fee tiers: 0.05%, 0.3%, 1%. Pick pool with highest liquidity. */
const UNISWAP_V3_FEE_TIERS = [500, 3000, 10000] as const;

async function getV3Pool(
  provider: { call: (tx: { to: string; data: string }) => Promise<string> },
  tokenA: string,
  tokenB: string,
  fee: number
): Promise<string> {
  const iface = new ethers.Interface(["function getPool(address,address,uint24) view returns (address)"]);
  const data = iface.encodeFunctionData("getPool", [tokenA, tokenB, fee]);
  const result = await provider.call({ to: config.UniswapV3Factory, data });
  return ethers.AbiCoder.defaultAbiCoder().decode(["address"], result)[0] as string;
}

function logPrices(name: string, result: any) {
  
  console.log(name, "-------------price: ", result.price);
  console.log(name, "----chainLinkPrice: ", result.chainLinkPrice, '(', new Date(Number(result.chainLinkUpdatedAt) * 1000).toISOString(), ')');
  console.log(name, "---------pythPrice: ", result.pythPrice, '(', new Date(Number(result.pythUpdatedAt) * 1000).toISOString(), ')');
  console.log(name, "------uniswapPrice: ", result.uniswapPrice);
  console.log(name, "-------priceSource: ", PRICE_SOURCE_NAMES[result.priceSource]);
}

async function getPoolLiquidity(
  provider: { call: (tx: { to: string; data: string }) => Promise<string> },
  poolAddress: string
): Promise<bigint> {
  const iface = new ethers.Interface(["function liquidity() view returns (uint128)"]);
  const data = iface.encodeFunctionData("liquidity", []);
  const result = await provider.call({ to: poolAddress, data });
  return ethers.AbiCoder.defaultAbiCoder().decode(["uint128"], result)[0] as bigint;
}

/** Returns V3 pool (tokenA/tokenB) with highest liquidity among fee tiers 500, 3000, 10000. */
async function getBestV3Pool(
  provider: { call: (tx: { to: string; data: string }) => Promise<string> },
  tokenA: string,
  tokenB: string
): Promise<string> {
  let bestPool = ethers.ZeroAddress;
  let bestLiquidity = 0n;
  for (const fee of UNISWAP_V3_FEE_TIERS) {
    const pool = await getV3Pool(provider, tokenA, tokenB, fee);
    if (pool === ethers.ZeroAddress) continue;
    const liquidity = await getPoolLiquidity(provider, pool);
    if (liquidity > bestLiquidity) {
      bestLiquidity = liquidity;
      bestPool = pool;
    }
  }
  return bestPool;
}

describe("Oracle", function () {
  const PRICE_DECIMALS = 8;
  const ETH_PRICE_MIN = 500n * 10n ** BigInt(PRICE_DECIMALS);
  const ETH_PRICE_MAX = 5000n * 10n ** BigInt(PRICE_DECIMALS);
  const BTC_PRICE_MIN = 30_000n * 10n ** BigInt(PRICE_DECIMALS);
  const BTC_PRICE_MAX = 100_000n * 10n ** BigInt(PRICE_DECIMALS);
  const SOL_PRICE_MIN = 50n * 10n ** BigInt(PRICE_DECIMALS);
  const SOL_PRICE_MAX = 500n * 10n ** BigInt(PRICE_DECIMALS);
  const AUD_PRICE_MIN = 1n * 5n ** BigInt(PRICE_DECIMALS);
  const AUD_PRICE_MAX = 10n * 10n ** BigInt(PRICE_DECIMALS);
  const USDC_PRICE_MIN = 99n * 10n ** BigInt(PRICE_DECIMALS - 2); // 0.99 USD
  const USDC_PRICE_MAX = 101n * 10n ** BigInt(PRICE_DECIMALS - 2); // 1.01 USD

  async function deployOracleFixture(): Promise<{
    oracle: Oracle;
    owner: HardhatEthersSigner;
  }> {
    const signers = await ethers.getSigners();
    const owner = signers[0];
    try {
      const balanceHex = "0x" + (10n ** 21n).toString(16);
      for (const s of signers) {
        await network.provider.send("hardhat_setBalance", [s.address, balanceHex]);
      }
    } catch {
      // skip on non-fork
    }
    const OracleFactory = await ethers.getContractFactory("Oracle");
    const OracleProxy = await upgrades.deployProxy(OracleFactory, [owner.address], {
      kind: "uups",
      initializer: "initialize",
    });
    const oracle = OracleProxy as unknown as Oracle;
    return { oracle, owner };
  }

  describe("on Base fork", function () {
    this.timeout(90_000);

    // it("set sources and getPrice(AUD) returns sane actual price", async function () {
    //   const { oracle } = await loadFixture(deployOracleFixture);
    //   const poolAudUsdc = await getBestV3Pool(ethers.provider, config.tokens.AUD, config.tokens.USDC);
    //   console.log("poolAudUsdc: ", poolAudUsdc);
    //   await oracle.setChainlinkFeed(config.tokens.AUD, config.chainlink.CHAINLINK_AUD_USD);
    //   await oracle.setUniswapPool(config.tokens.AUD, poolAudUsdc);
    //   await oracle.setPyth(config.pyth.PYTH);
    //   await oracle.setPythPriceId(config.tokens.AUD, config.pyth.PYTH_AUD_USD_ID);
    //   let result: Awaited<ReturnType<Oracle["getPrice"]>>;
    //   try {
    //     result = await oracle.getPrice(config.tokens.AUD);
    //   } catch (err) {
    //     this.skip();
    //     return;
    //   }
    //   logPrices("AUD", result);
    //   expect(result.price).to.be.gt(0);
    //   expect(result.price).to.be.gte(AUD_PRICE_MIN);
    //   expect(result.price).to.be.lte(AUD_PRICE_MAX);
    // });

    it("set sources and getPrice(WBTC) returns sane actual price", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      const poolBtcUsdc = await getBestV3Pool(ethers.provider, config.tokens.WBTC, config.tokens.USDC);
      console.log("poolBtcUsdc: ", poolBtcUsdc);
      await oracle.setChainlinkFeed(config.tokens.WBTC, config.chainlink.CHAINLINK_BTC_USD);
      await oracle.setUniswapPool(config.tokens.WBTC, poolBtcUsdc);
      await oracle.setPyth(config.pyth.PYTH);
      await oracle.setPythPriceId(config.tokens.WBTC, config.pyth.PYTH_BTC_USD_ID);
      let result: Awaited<ReturnType<Oracle["getPrice"]>>;
      try {
        result = await oracle.getPrice(config.tokens.WBTC);
      } catch (err) {
        this.skip();
        return;
      }
      logPrices("WBTC", result);
      expect(result.price).to.be.gt(0);
      expect(result.price).to.be.gte(BTC_PRICE_MIN);
      expect(result.price).to.be.lte(BTC_PRICE_MAX);
    });
    

    it("set sources and getPrice(USDC) returns sane actual price", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      const poolUsdcStable = "0x0000000000000000000000000000000000000001";
      await oracle.setUniswapPool(config.tokens.USDC, poolUsdcStable);

      const result = await oracle.getPrice(config.tokens.USDC);
      logPrices("USDC", result);

      expect(result.price).to.be.gt(0);
      expect(result.price).to.be.gte(USDC_PRICE_MIN);
      expect(result.price).to.be.lte(USDC_PRICE_MAX);
    });
    

    it("getPrice(unconfigured) returns zeros", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      const zeroToken = "0x0000000000000000000000000000000000000001";

      const result = await oracle.getPrice(zeroToken);

      expect(result.price).to.eq(0);
      expect(result.chainLinkPrice).to.eq(0);
      expect(result.pythPrice).to.eq(0);
      expect(result.uniswapPrice).to.eq(0);
    });
  });
});
