import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { parseUnits } from "ethers";
import { FixedRateIrm, Lending8, MockOracle, USDC, WBTC } from "../../typechain-types";

const WAD = 10n ** 18n;
const PRICE_DECIMALS = 8;

/** WBTC price ~$67,000 in oracle scale (8 decimals). */
const WBTC_PRICE_USD = 67_000n * 10n ** BigInt(PRICE_DECIMALS);
/** USDC price $1 in oracle scale. */
const USDC_PRICE_USD = 1n * 10n ** BigInt(PRICE_DECIMALS);
/** LLTV 80%. */
const LLTV_80 = (80n * WAD) / 100n;

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

async function deployLending8Fixture(): Promise<{
  lending8: Lending8;
  fixedRateIrm: FixedRateIrm;
  oracle: MockOracle;
  usdc: USDC;
  wbtc: WBTC;
  marketParams: MarketParams;
  owner: HardhatEthersSigner;
  user: HardhatEthersSigner;
}> {
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

  // 5% APY, rate per second: WAD * 0.05 / (365 * 24 * 3600)
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

  await usdc.connect(owner).transfer(await user.getAddress(), parseUnits("100000", 6));
  await wbtc.connect(owner).transfer(await user.getAddress(), parseUnits("1", 8));

  return {
    lending8,
    fixedRateIrm,
    oracle,
    usdc,
    wbtc,
    marketParams,
    owner,
    user,
  };
}

describe("Lending8", function () {
  describe("deploy and setup", function () {
    it("should deploy Lending8, Oracle, tokens and create market", async function () {
      const { lending8, oracle, usdc, wbtc } = await loadFixture(deployLending8Fixture);
      expect(await lending8.oracle()).to.equal(await oracle.getAddress());
      expect(await usdc.decimals()).to.equal(6);
      expect(await wbtc.decimals()).to.equal(8);
    });
  });

  describe("supply", function () {
    it("should supply USDC to market", async function () {
      const { lending8, usdc, marketParams, user } = await loadFixture(deployLending8Fixture);
      const supplyAmount = parseUnits("10000", 6);
      await usdc.connect(user).approve(await lending8.getAddress(), supplyAmount);
      await lending8
        .connect(user)
        .supply(marketParams, supplyAmount, 0n, await user.getAddress(), "0x");
      const pos = await lending8.position(buildMarketId(marketParams), await user.getAddress());
      expect(pos.supplyShares).to.be.gt(0);
    });
  });

  describe("supplyCollateral and borrow (decimals fix)", function () {
    it("should supply collateral and borrow within correct maxBorrow (WBTC 8d, USDC 6d)", async function () {
      const { lending8, usdc, wbtc, marketParams, user } = await loadFixture(deployLending8Fixture);

      await usdc.connect(user).approve(await lending8.getAddress(), parseUnits("10000", 6));
      await lending8.connect(user).supply(marketParams, parseUnits("10000", 6), 0n, user.address, "0x");

      const collateralAmount = parseUnits("0.001", 8);
      await wbtc.connect(user).approve(await lending8.getAddress(), collateralAmount);
      await lending8.connect(user).supplyCollateral(marketParams, collateralAmount, user.address, "0x");

      const expectedMaxBorrowUsd = 67_000 * 0.001 * 0.8;
      const expectedMaxBorrowRaw = BigInt(Math.floor(expectedMaxBorrowUsd * 1e6));
      const borrowAmount = expectedMaxBorrowRaw - 1n;

      const balanceBefore = await usdc.balanceOf(user.address);
      await lending8.connect(user).borrow(marketParams, borrowAmount, 0n, user.address, user.address);
      const balanceAfter = await usdc.balanceOf(user.address);
      const borrowed = balanceAfter - balanceBefore;

      expect(borrowed).to.be.gte(parseUnits("53", 6));
      expect(borrowed).to.be.lte(parseUnits("54", 6));
    });

    it("should revert when borrowing more than maxBorrow (overcollateralization)", async function () {
      const { lending8, usdc, wbtc, marketParams, user } = await loadFixture(deployLending8Fixture);

      await usdc.connect(user).approve(await lending8.getAddress(), parseUnits("100000", 6));
      await lending8.connect(user).supply(marketParams, parseUnits("100000", 6), 0n, user.address, "0x");

      const collateralAmount = parseUnits("0.001", 8);
      await wbtc.connect(user).approve(await lending8.getAddress(), collateralAmount);
      await lending8.connect(user).supplyCollateral(marketParams, collateralAmount, user.address, "0x");

      const overBorrow = parseUnits("100", 6);
      await expect(
        lending8.connect(user).borrow(marketParams, overBorrow, 0n, user.address, user.address)
      ).to.be.revertedWith("insufficient collateral");
    });
  });

  describe("repay and withdrawCollateral", function () {
    it("should repay and withdraw collateral", async function () {
      const { lending8, usdc, wbtc, marketParams, user } = await loadFixture(deployLending8Fixture);

      await usdc.connect(user).approve(await lending8.getAddress(), parseUnits("100000", 6));
      await lending8.connect(user).supply(marketParams, parseUnits("10000", 6), 0n, user.address, "0x");

      const collateralAmount = parseUnits("0.001", 8);
      await wbtc.connect(user).approve(await lending8.getAddress(), collateralAmount);
      await lending8.connect(user).supplyCollateral(marketParams, collateralAmount, user.address, "0x");

      const borrowAmount = parseUnits("50", 6);
      await lending8.connect(user).borrow(marketParams, borrowAmount, 0n, user.address, user.address);

      await usdc.connect(user).approve(await lending8.getAddress(), borrowAmount);
      await lending8.connect(user).repay(marketParams, borrowAmount, 0n, user.address, "0x");

      const wbtcBefore = await wbtc.balanceOf(user.address);
      await lending8.connect(user).withdrawCollateral(marketParams, collateralAmount, user.address, user.address);
      const wbtcAfter = await wbtc.balanceOf(user.address);
      expect(wbtcAfter - wbtcBefore).to.equal(collateralAmount);
    });
  });

  describe("liquidation guard", function () {
    // The only FlashLiquidator case that cannot live in Foundry: "position is healthy" is raised by
    // Lending8 itself, and every Foundry suite drives FlashLiquidator through a mock that does not
    // model position health. Everything else about FlashLiquidator is covered in
    // test/foundry/unit/FlashLiquidator*.t.sol against the real contract logic.
    it("a healthy position cannot be liquidated", async function () {
      const { lending8, usdc, wbtc, marketParams, owner, user } = await loadFixture(deployLending8Fixture);

      await usdc.connect(user).approve(await lending8.getAddress(), parseUnits("100000", 6));
      await lending8.connect(user).supply(marketParams, parseUnits("10000", 6), 0n, user.address, "0x");

      const collateralAmount = parseUnits("0.001", 8);
      await wbtc.connect(user).approve(await lending8.getAddress(), collateralAmount);
      await lending8.connect(user).supplyCollateral(marketParams, collateralAmount, user.address, "0x");

      // 50 USDC against a 53.6 USDC limit, so the position stays well inside LLTV
      await lending8.connect(user).borrow(marketParams, parseUnits("50", 6), 0n, user.address, user.address);

      const FlashLiquidatorFactory = await ethers.getContractFactory("FlashLiquidator", owner);
      const flashLiqProxy = await upgrades.deployProxy(
        FlashLiquidatorFactory,
        [await lending8.getAddress(), owner.address, ethers.ZeroAddress],
        { kind: "uups", initializer: "initialize" }
      );
      const flashLiq = await ethers.getContractAt("FlashLiquidator", await flashLiqProxy.getAddress());

      // Funded, so the call gets past the own-balance check and actually reaches Lending8
      await usdc.connect(owner).transfer(await flashLiq.getAddress(), parseUnits("1000", 6));

      await expect(
        flashLiq.liquidate(buildMarketId(marketParams), user.address, parseUnits("10", 6))
      ).to.be.revertedWith("position is healthy");
    });
  });
});
