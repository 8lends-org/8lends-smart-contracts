/**
 * Deploy new Fundraise implementation and print Gnosis Safe calldata
 * for upgradeToAndCall(newImpl, "0x") — does NOT execute the upgrade.
 *
 * Usage:
 *   npx hardhat run scripts/upgrade-fundraise.ts --network <network>
 *
 * Required config key: Fundraise (proxy address)
 * Writes: Fundraise_impl_new
 */

import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "./helpers";

dotenv.config();

type Config = Record<string, string>;

async function main(): Promise<void> {
  if (hre.network.name === "hardhat" && process.env.ALLOW_FORK !== "1") {
    throw new Error("Refusing to run against the in-process fork. Pass --network base or set ALLOW_FORK=1.");
  }

  // ── network + config ────────────────────────────────────────────────────────
  const net = await ethers.provider.getNetwork();
  console.log("\n" + "=".repeat(80));
  console.log(`Network: ${net.name} (chainId: ${net.chainId})`);
  console.log("=".repeat(80));

  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = (await readJsonFile(filePath)) as Config;

  const proxyAddress = config.Fundraise;
  if (!proxyAddress) {
    console.error(`\nERROR: 'Fundraise' not found in config: ${filePath}`);
    process.exit(1);
  }

  console.log(`\nContract:      Fundraise`);
  console.log(`Proxy address: ${proxyAddress}`);

  // Check current owner + implementation
  const fundraise = await ethers.getContractAt("Fundraise", proxyAddress);
  const currentOwner = await (fundraise as unknown as { owner(): Promise<string> }).owner();
  console.log(`Current owner: ${currentOwner}`);

  const currentImpl = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log(`Current impl:  ${currentImpl}`);

  // ── deploy new Fundraise implementation ─────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("Deploying new Fundraise implementation...");
  console.log("=".repeat(80));

  const ContractFactory = await ethers.getContractFactory("Fundraise");
  const newImpl = await ContractFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();
  console.log(`New impl deployed: ${newImplAddress}`);

  // ── encode upgradeToAndCall calldata ────────────────────────────────────────
  const upgradeCalldata = fundraise.interface.encodeFunctionData("upgradeToAndCall", [
    newImplAddress,
    "0x",
  ]);

  // ── print Safe Transaction Builder data ─────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("DATA FOR TRANSACTION BUILDER IN GNOSIS SAFE");
  console.log("=".repeat(80));
  console.log("\n1. Open: https://app.safe.global/");
  console.log("2. Select your Safe");
  console.log("3. Go to Apps -> Transaction Builder");
  console.log("4. Enter the following data:\n");

  console.log("┌─────────────────────────────────────────────────────────────────┐");
  console.log("│ Safe Transaction Entry                                           │");
  console.log("├─────────────────────────────────────────────────────────────────┤");
  console.log(`│ to:        ${proxyAddress}`);
  console.log("│ value:     0");
  console.log(`│ data:      ${upgradeCalldata}`);
  console.log("│ operation: 0");
  console.log("└─────────────────────────────────────────────────────────────────┘");

  console.log("\n" + "=".repeat(80));
  console.log("UPGRADE DETAILS");
  console.log("=".repeat(80));
  console.log(`Contract:     Fundraise`);
  console.log(`Proxy:        ${proxyAddress}`);
  console.log(`Old impl:     ${currentImpl}`);
  console.log(`New impl:     ${newImplAddress}`);
  console.log(`Owner (Safe): ${currentOwner}`);
  console.log("=".repeat(80));

  // ── update config ───────────────────────────────────────────────────────────
  config.Fundraise_impl_new = newImplAddress;
  await writeJsonFile(filePath, config);
  console.log(`\nNew impl saved to config as 'Fundraise_impl_new': ${newImplAddress}`);

  console.log("\nNext steps:");
  console.log("  1. Copy the transaction data above to Safe Transaction Builder");
  console.log("  2. Review transaction details carefully");
  console.log("  3. Create batch and collect signatures from Safe owners");
  console.log("  4. Execute when signature threshold is reached\n");
}

main().catch((error: unknown) => {
  console.error("\nERROR:", (error as Error).message ?? error);
  process.exitCode = 1;
  process.exit(1);
});
