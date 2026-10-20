import { expect } from "chai";
import { ethers, network } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { AbiCoder, keccak256, parseEther, parseUnits, toBeHex, zeroPadValue } from "ethers";
import { loadConfig } from "../scripts/utils/config";

/**
 * Rewards2 crossing the cutover on the real Base deployment, on the in-process fork.
 *
 * The implementation that is live now runs the token era: it creates the vesting and pays the first
 * claim. The proxy is then upgraded the way the Safe will do it, with initializeCutover in the same call,
 * and the new code has to treat everything unlocked by that moment as still owed in tokens. Source of
 * the live implementation is not in the repo (it was never verified), which is why this runs against
 * its bytecode on the fork rather than against a copy.
 *
 * The Safe is impersonated: nothing here is signed or leaves the fork.
 */
describe("Rewards2 cutover on the Base fork", function () {
  this.timeout(600_000);

  const WEEK = 7 * 24 * 3600;
  const DAYS3 = 3 * 24 * 3600; // keeps every checkpoint clear of a week boundary
  const BP = 1_000_000n;
  const WEEKLY = 25_000n;
  const RATE = 20_000n; // $0.02 against six-decimal USDC
  const BONUS_B = 260_000n; // a ratchet left by the withdrawn sell bonus

  const OLD_ABI = [
    "function createVesting(address[],uint256[])",
    "function claim()",
    "function getVestingInfo(address,uint256) view returns (uint256,uint256,uint256,uint256,bool)",
    "function owner() view returns (address)",
    "function upgradeToAndCall(address,bytes)",
  ];

  /** Unlocked by `weeks` full weeks after the start, the way both versions define it. */
  function unlocked(total: bigint, weeks: number, bonus = 0n): bigint {
    const weeksUnlocked = BigInt(weeks) + 1n;
    if (weeksUnlocked >= 40n) return total;
    const u = (total * weeksUnlocked * WEEKLY) / BP + (total * bonus) / BP;
    return u > total ? total : u;
  }

  const usdcFor = (tokens: bigint) => (tokens * RATE) / 10n ** 18n;

  async function impersonate(address: string) {
    await network.provider.send("hardhat_impersonateAccount", [address]);
    await network.provider.send("hardhat_setBalance", [address, toBeHex(parseEther("10"))]);
    return ethers.getSigner(address);
  }

  /** Writes an ERC20 balance by finding the slot of its balance mapping. */
  async function setErc20Balance(tokenAddress: string, holder: string, amount: bigint) {
    const erc20 = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", tokenAddress);
    for (let slot = 0; slot < 20; slot++) {
      const key = keccak256(AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [holder, slot]));
      const before = await network.provider.send("eth_getStorageAt", [tokenAddress, key, "latest"]);
      await network.provider.send("hardhat_setStorageAt", [tokenAddress, key, zeroPadValue(toBeHex(amount), 32)]);
      if ((await erc20.balanceOf(holder)) === amount) return;
      await network.provider.send("hardhat_setStorageAt", [tokenAddress, key, before]);
    }
    throw new Error(`balance slot of ${tokenAddress} not found`);
  }

  it("pays the token era in tokens and the rest in USDC, across a real upgrade", async function () {
    // Calls against the fork block itself are refused as historical; one mined block moves past it.
    await network.provider.send("evm_mine", []);

    const config = loadConfig(8453);
    const proxyAddress: string = config.Rewards2;
    const usdcAddress: string = config.USDC;

    const old = await ethers.getContractAt(OLD_ABI, proxyAddress);
    const safe = await impersonate(await old.owner());
    const token = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.token);
    const usdc = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", usdcAddress);
    const registry = await ethers.getContractAt("ManagerRegistry", config.ManagerRegistry);

    const [, a, b, admin] = await ethers.getSigners();
    const totalA = parseEther("10000");
    const totalB = parseEther("8000");

    // ── Token era, on the live implementation ──
    const start = (await time.latest()) + 100;
    await time.setNextBlockTimestamp(start);
    await old.connect(safe).getFunction("createVesting")([a.address, b.address], [totalA, totalB]);

    // B carries a ratchet. Nothing writes one, so it is planted where the chain keeps it:
    // userMaxAdditionalUnlockUsed, slot 10, vesting 0.
    const inner = keccak256(AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [b.address, 10]));
    const bonusSlot = keccak256(AbiCoder.defaultAbiCoder().encode(["uint256", "bytes32"], [0, inner]));
    await network.provider.send("hardhat_setStorageAt", [proxyAddress, bonusSlot, zeroPadValue(toBeHex(BONUS_B), 32)]);

    await time.setNextBlockTimestamp(start + 5 * WEEK + DAYS3);
    const aTok0 = await token.balanceOf(a.address);
    await old.connect(a).getFunction("claim")();
    const aOldEra = (await token.balanceOf(a.address)) - aTok0;
    expect(aOldEra).to.equal(unlocked(totalA, 5), "the live code pays the curve this test assumes");

    // ── Upgrade, as the Safe will run it ──
    await time.setNextBlockTimestamp(start + 10 * WEEK + DAYS3);
    await network.provider.send("evm_mine", []);
    const [, , oldOwedA] = await old.getVestingInfo(a.address, 0);
    const [, , oldOwedB] = await old.getVestingInfo(b.address, 0);

    const impl = await (await ethers.getContractFactory("Rewards2")).deploy();
    const rewards2 = await ethers.getContractAt("Rewards2", proxyAddress);
    const upgrade = await rewards2
      .connect(safe)
      .upgradeToAndCall(await impl.getAddress(), rewards2.interface.encodeFunctionData("initializeCutover"));
    const upgradedAt = (await ethers.provider.getBlock((await upgrade.wait())!.blockNumber))!.timestamp;
    expect(await rewards2.cutover()).to.equal(upgradedAt);

    // Right after the upgrade everything the old code owed is owed in tokens, and nothing in USDC.
    const [aTokNow, aUsdcNow] = await rewards2.getClaimable(a.address);
    const [bTokNow, bUsdcNow] = await rewards2.getClaimable(b.address);
    expect(aTokNow).to.equal(oldOwedA);
    expect(bTokNow).to.equal(oldOwedB);
    expect(aUsdcNow).to.equal(0n);
    expect(bUsdcNow).to.equal(0n);
    expect(oldOwedA).to.equal(unlocked(totalA, 10) - aOldEra);
    expect(oldOwedB).to.equal(unlocked(totalB, 10, BONUS_B));

    // ── USDC era ──
    // The rate and the batches are the admin's, so the role has to exist on the fork first.
    await registry.connect(safe).setAdminStatus(admin.address, true);
    await rewards2.connect(admin).setRedemptionRate(RATE);
    await setErc20Balance(usdcAddress, proxyAddress, parseUnits("1000000", 6));

    const balances = async (who: string) => [await token.balanceOf(who), await usdc.balanceOf(who)];

    // A claims directly, B is paid by the batch.
    await time.setNextBlockTimestamp(start + 20 * WEEK + DAYS3);
    let [aTok, aUsd] = await balances(a.address);
    // Two calls now, and the token era has to go first.
    await rewards2.connect(a).claimTokens();
    await rewards2.connect(a).claimUsdc();
    let [aTok2, aUsd2] = await balances(a.address);
    expect(aTok2 - aTok).to.equal(oldOwedA, "the token era, still in tokens");
    expect(aUsd2 - aUsd).to.equal(usdcFor(unlocked(totalA, 20) - unlocked(totalA, 10)));

    await time.setNextBlockTimestamp(start + 20 * WEEK + DAYS3 + 60);
    let [bTok, bUsd] = await balances(b.address);
    await rewards2.connect(admin).claimTokensBatch([b.address]);
    await rewards2.connect(admin).claimUsdcBatch([b.address]);
    let [bTok2, bUsd2] = await balances(b.address);
    expect(bTok2 - bTok).to.equal(oldOwedB, "the batch pays the token era in tokens too");
    expect(bUsd2 - bUsd).to.equal(usdcFor(unlocked(totalB, 20, BONUS_B) - unlocked(totalB, 10, BONUS_B)));

    // Run the schedule out.
    await time.setNextBlockTimestamp(start + 61 * WEEK);
    [aTok, aUsd] = await balances(a.address);
    await expect(rewards2.connect(a).claimTokens()).to.be.revertedWith("No tokens to claim");
    await rewards2.connect(a).claimUsdc();
    [aTok2, aUsd2] = await balances(a.address);
    expect(aTok2 - aTok).to.equal(0n, "nothing after the cutover is paid in tokens");
    expect(aUsd2 - aUsd).to.equal(usdcFor(totalA - unlocked(totalA, 20)));

    [bTok, bUsd] = await balances(b.address);
    await rewards2.connect(admin).claimTokensBatch([b.address]);
    await rewards2.connect(admin).claimUsdcBatch([b.address]);
    [bTok2, bUsd2] = await balances(b.address);
    expect(bTok2 - bTok).to.equal(0n);
    expect(bUsd2 - bUsd).to.equal(usdcFor(totalB - unlocked(totalB, 20, BONUS_B)));

    // Totals: tokens are exactly what had unlocked by the cutover, and the grant is spent in full.
    expect(aOldEra + oldOwedA).to.equal(unlocked(totalA, 10));
    expect(oldOwedB).to.equal(unlocked(totalB, 10, BONUS_B));
    expect((await rewards2.vestings(a.address, 0)).claimedAmount).to.equal(totalA);
    expect((await rewards2.vestings(b.address, 0)).claimedAmount).to.equal(totalB);
    expect(await registry.isPool(a.address)).to.equal(false, "the transfer flag must not outlive the claim");
  });
});
