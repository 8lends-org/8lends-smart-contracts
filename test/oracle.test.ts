import { expect } from "chai";
import { ethers, network } from "hardhat";
import { upgrades } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { Oracle } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { readFileSync } from "fs";
import { join } from "path";

/** Cast over JSON.parse with no validation: a declared field may be absent from the file. */
const config:{
  "UniswapV3Factory": string;
  "tokens": {
    "WETH": string;
    "USDC": string;
    /** WBTC and cbBTC are two config keys for the same address: base has no WBTC, only cbBTC. */
    "cbBTC": string;
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
    "PYTH_AUD_USD_ID"?: string;
  }
} = JSON.parse(readFileSync(join(__dirname, `../scripts/config/8453-config.json`), "utf8"));

/** Mirrors Oracle.PriceSource; the index is the enum value returned by getPrice. */
const PRICE_SOURCE_NAMES = [
  "None",
  "Pyth",
  "ChainLink",
  "Uniswap",
];

const enum PriceSource {
  None = 0,
  Pyth = 1,
  ChainLink = 2,
  Uniswap = 3,
}

/** Uniswap V3 fee tiers: 0.05%, 0.3%, 1%. Pick pool with highest liquidity. */
const UNISWAP_V3_FEE_TIERS = [500, 3000, 10000] as const;

type PriceResult = Awaited<ReturnType<Oracle["getPrice"]>>;

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

/** Price of the source getPrice named as chosen. */
function priceOfChosenSource(r: PriceResult): bigint {
  switch (Number(r.priceSource)) {
    case PriceSource.Pyth: return r.pythPrice;
    case PriceSource.ChainLink: return r.chainLinkPrice;
    case PriceSource.Uniswap: return r.uniswapPrice;
    default: throw new Error("priceSource is None — no source was chosen");
  }
}

/** Sources the oracle managed to read; zero means unavailable, not free. */
function availableSources(r: PriceResult): { name: string; price: bigint }[] {
  return [
    { name: "Pyth", price: r.pythPrice },
    { name: "ChainLink", price: r.chainLinkPrice },
    { name: "Uniswap", price: r.uniswapPrice },
  ].filter((s) => s.price > 0n);
}

/** Mirrors Oracle._isWithinDeviation: [ref·(100-pct)/100, ref·(100+pct)/100]. */
function deviationBounds(reference: bigint, percent: bigint): { min: bigint; max: bigint } {
  return {
    min: (reference * (100n - percent)) / 100n,
    max: (reference * (100n + percent)) / 100n,
  };
}

describe("Oracle", function () {
  const PRICE_DECIMALS = 8;
  const ONE_USD = 10n ** BigInt(PRICE_DECIMALS);

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

  /** All three sources wired to the live base feeds for cbBTC. */
  async function btcOracleFixture(): Promise<{ oracle: Oracle; result: PriceResult }> {
    const { oracle } = await deployOracleFixture();
    const token = config.tokens.cbBTC;
    const poolBtcUsdc = await getBestV3Pool(ethers.provider, token, config.tokens.USDC);
    await oracle.setChainlinkFeed(token, config.chainlink.CHAINLINK_BTC_USD);
    await oracle.setUniswapPool(token, poolBtcUsdc);
    await oracle.setPyth(config.pyth.PYTH);
    await oracle.setPythPriceId(token, config.pyth.PYTH_BTC_USD_ID);
    const result = await oracle.getPrice(token);
    return { oracle, result };
  }

  describe("on Base fork", function () {
    this.timeout(90_000);

    // cbBTC reads live Chainlink, Pyth and Uniswap V3, so nothing below may depend on where BTC
    // trades: each check is a property the oracle promises, with tolerances read from the contract.
    it("picks a source, names it, and returns exactly that source's price", async function () {
      const { result } = await loadFixture(btcOracleFixture);
      logPrices("cbBTC", result);

      expect(Number(result.priceSource), "no source passed freshness + deviation").to.not.equal(PriceSource.None);
      expect(result.price).to.be.gt(0);
      // The cascade's promise: the aggregate is the named source, not a blend.
      expect(result.price).to.equal(priceOfChosenSource(result));
    });

    it("agrees with every available source within the contract's own deviation limit", async function () {
      const { oracle, result } = await loadFixture(btcOracleFixture);
      const percent = await oracle.maxPriceChangePercent();
      const sources = availableSources(result);

      // Below two feeds the check would be vacuous.
      expect(sources.length, "need at least two live sources to compare").to.be.gte(2);

      for (const source of sources) {
        const { min, max } = deviationBounds(source.price, percent);
        expect(result.price, `price diverges from ${source.name} by more than ${percent}%`)
          .to.be.gte(min).and.to.be.lte(max);
      }
    });

    it("does not pick a source that is past its max age", async function () {
      const { oracle, result } = await loadFixture(btcOracleFixture);
      const now = BigInt(await time.latest());

      if (Number(result.priceSource) === PriceSource.Pyth) {
        expect(now - result.pythUpdatedAt).to.be.lte(await oracle.pythMaxAgeSec());
      } else if (Number(result.priceSource) === PriceSource.ChainLink) {
        expect(now - result.chainLinkUpdatedAt).to.be.lte(await oracle.chainLinkMaxAgeSec());
        // Chainlink wins only when Pyth was unusable — pin that down.
        const pythUsable =
          result.pythPrice > 0n && now - result.pythUpdatedAt <= (await oracle.pythMaxAgeSec());
        expect(pythUsable, "Pyth was fresh, so it should have been chosen over ChainLink").to.equal(false);
      }
      // Uniswap is a TWAP with no updatedAt — nothing to age-check.
    });

    /**
     * AUD (the AUDD stablecoin) is wired in the deployed Oracle, so this path is live. Two config
     * problems make it weaker than cbBTC:
     *
     * 1. Single source — no Pyth id in the config, no AUDD/USDC pool on Uniswap V3 at any fee tier.
     *    _passesDeviationCheck skips zero-priced sources, so for AUD it checks nothing.
     * 2. No freshness margin — the feed's heartbeat is 24h and chainLinkMaxAgeSec is also 24h, with
     *    observed intervals slightly over (24h 00m 24s). In that gap ChainLink is rejected and,
     *    lacking a fallback, getPrice returns 0. Fix: raise the limit or add a second source.
     *
     * Hence both outcomes are asserted — otherwise the test would go red daily on a condition that
     * is currently harmless, since nothing consumes AUD yet.
     */
    it("resolves AUD from its single ChainLink source, or correctly rejects it as stale", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      await oracle.setChainlinkFeed(config.tokens.AUD, config.chainlink.CHAINLINK_AUD_USD);

      // If an id is ever added to the config, wire Pyth in here.
      expect(config.pyth.PYTH_AUD_USD_ID, "PYTH_AUD_USD_ID appeared in the config — wire Pyth into this test")
        .to.equal(undefined);

      const result = await oracle.getPrice(config.tokens.AUD);
      logPrices("AUD", result);

      const now = BigInt(await time.latest());
      const maxAge = await oracle.chainLinkMaxAgeSec();

      expect(result.chainLinkPrice, "ChainLink returned no AUD price at all").to.be.gt(0);
      expect(result.pythPrice, "no Pyth id is configured for AUD").to.equal(0);
      expect(result.uniswapPrice, "no Uniswap pool exists for AUDD on base").to.equal(0);

      if (Number(result.priceSource) === PriceSource.ChainLink) {
        expect(result.price).to.equal(result.chainLinkPrice);
        expect(now - result.chainLinkUpdatedAt).to.be.lte(maxAge);
      } else {
        // The only legitimate alternative: rejected as past its max age.
        expect(Number(result.priceSource)).to.equal(PriceSource.None);
        expect(result.price).to.equal(0);
        expect(now - result.chainLinkUpdatedAt, "no source chosen, yet ChainLink was within max age")
          .to.be.gt(maxAge);
        console.warn(
          `  AUD has no price right now: ChainLink is ${(Number(now - result.chainLinkUpdatedAt) / 3600).toFixed(1)}h ` +
          `old against a ${Number(maxAge) / 3600}h limit, and AUD has no fallback source.`
        );
      }
    });

    // address(1) is the documented sentinel for "stablecoin without a real pool" — the oracle
    // returns exactly 1 USD, nothing live involved, so assert it exactly.
    it("returns exactly 1 USD for a stablecoin pinned to the address(1) sentinel", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      await oracle.setUniswapPool(config.tokens.USDC, "0x0000000000000000000000000000000000000001");

      const result = await oracle.getPrice(config.tokens.USDC);
      logPrices("USDC", result);

      expect(result.price).to.equal(ONE_USD);
      expect(Number(result.priceSource)).to.equal(PriceSource.Uniswap);
    });

    it("getPrice(unconfigured) returns zeros", async function () {
      const { oracle } = await loadFixture(deployOracleFixture);
      const unconfiguredToken = "0x000000000000000000000000000000000000dEaD";

      const result = await oracle.getPrice(unconfiguredToken);

      expect(result.price).to.eq(0);
      expect(result.chainLinkPrice).to.eq(0);
      expect(result.pythPrice).to.eq(0);
      expect(result.uniswapPrice).to.eq(0);
      expect(Number(result.priceSource)).to.equal(PriceSource.None);
    });
  });
});
