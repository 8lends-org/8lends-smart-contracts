/**
 * Print Gnosis Safe calldata for Fundraise.setAmlGateway(EscrowFactory)
 * Does NOT execute the transaction — multisig flow only.
 *
 * Usage:
 *   npx hardhat run scripts/set-aml-gateway.ts --network <network>
 *
 * Required config keys: Fundraise (proxy), EscrowFactory (proxy)
 *
 * Also prints rollback calldata: setAmlGateway(address(0))
 */

import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "./helpers";

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

  const fundraiseProxy = config.Fundraise;
  if (!fundraiseProxy) {
    console.error(`\nERROR: 'Fundraise' not found in config: ${filePath}`);
    process.exit(1);
  }

  const escrowFactoryProxy = config.EscrowFactory;
  if (!escrowFactoryProxy) {
    console.error(`\nERROR: 'EscrowFactory' not found in config: ${filePath}`);
    console.error("Run deploy-escrow.ts first to deploy EscrowFactory.");
    process.exit(1);
  }

  console.log(`\nFundraise proxy:   ${fundraiseProxy}`);
  console.log(`EscrowFactory:     ${escrowFactoryProxy}`);

  // ── encode calldata ─────────────────────────────────────────────────────────
  const fundraise = await ethers.getContractAt("Fundraise", fundraiseProxy);

  const setGatewayCalldata = fundraise.interface.encodeFunctionData("setAmlGateway", [
    escrowFactoryProxy,
  ]);

  const rollbackCalldata = fundraise.interface.encodeFunctionData("setAmlGateway", [
    ethers.ZeroAddress,
  ]);

  // ── print Safe Transaction Builder data ─────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("DATA FOR TRANSACTION BUILDER IN GNOSIS SAFE — setAmlGateway");
  console.log("=".repeat(80));
  console.log("\n1. Open: https://app.safe.global/");
  console.log("2. Select your Safe");
  console.log("3. Go to Apps -> Transaction Builder");
  console.log("4. Enter the following data:\n");

  console.log("┌─────────────────────────────────────────────────────────────────┐");
  console.log("│ Safe Transaction Entry — SET AML GATEWAY                         │");
  console.log("├─────────────────────────────────────────────────────────────────┤");
  console.log(`│ to:        ${fundraiseProxy}`);
  console.log("│ value:     0");
  console.log(`│ data:      ${setGatewayCalldata}`);
  console.log("│ operation: 0");
  console.log("└─────────────────────────────────────────────────────────────────┘");

  // ── rollback calldata ───────────────────────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("ROLLBACK CALLDATA — setAmlGateway(address(0))");
  console.log("=".repeat(80));
  console.log("\nKeep this ready in case you need to disable AML gateway:\n");

  console.log("┌─────────────────────────────────────────────────────────────────┐");
  console.log("│ Safe Transaction Entry — ROLLBACK (disable AML gateway)          │");
  console.log("├─────────────────────────────────────────────────────────────────┤");
  console.log(`│ to:        ${fundraiseProxy}`);
  console.log("│ value:     0");
  console.log(`│ data:      ${rollbackCalldata}`);
  console.log("│ operation: 0");
  console.log("└─────────────────────────────────────────────────────────────────┘");

  console.log("\n" + "=".repeat(80));
  console.log("TRANSACTION DETAILS");
  console.log("=".repeat(80));
  console.log(`Fundraise proxy:   ${fundraiseProxy}`);
  console.log(`EscrowFactory:     ${escrowFactoryProxy}`);
  console.log(`Set calldata:      ${setGatewayCalldata}`);
  console.log(`Rollback calldata: ${rollbackCalldata}`);
  console.log("=".repeat(80));

  console.log("\nNext steps:");
  console.log("  1. Copy the SET AML GATEWAY data to Safe Transaction Builder");
  console.log("  2. Review that EscrowFactory address is correct");
  console.log("  3. Create batch and collect signatures from Safe owners");
  console.log("  4. Execute when signature threshold is reached");
  console.log("  5. Keep the ROLLBACK calldata somewhere safe for emergency use\n");
}

main().catch((error: unknown) => {
  console.error("\nERROR:", (error as Error).message ?? error);
  process.exitCode = 1;
  process.exit(1);
});
