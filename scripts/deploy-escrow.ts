/**
 * Deploy AmlEscrow implementation + EscrowFactory (UUPS proxy)
 *
 * Usage:
 *   SIGNER=0x... npx hardhat run scripts/deploy-escrow.ts --network <network>
 *
 * Optional env vars:
 *   VERIFY=true   — run etherscan verification after deployment
 *
 * Required config keys: Fundraise, USDC
 * Writes: AmlEscrow_impl, EscrowFactory_impl, EscrowFactory
 */

import dotenv from "dotenv";
import hre, { ethers, upgrades } from "hardhat";
import { readJsonFile, writeJsonFile } from "./utils/helpers";
import { requireRealNetwork } from "./utils/network-guard";

dotenv.config();

type Config = Record<string, string>;

async function main(): Promise<void> {
  await requireRealNetwork();
  // ── env validation ──────────────────────────────────────────────────────────
  const signerAddr = process.env.SIGNER;
  if (!signerAddr || signerAddr === "0x0000000000000000000000000000000000000000") {
    console.error("\nERROR: SIGNER env var must be set to a non-zero address");
    console.error(
      "Usage: SIGNER=0x... npx hardhat run scripts/deploy-escrow.ts --network <network>"
    );
    process.exit(1);
  }
  if (!ethers.isAddress(signerAddr)) {
    console.error(`\nERROR: SIGNER is not a valid address: ${signerAddr}`);
    process.exit(1);
  }

  const verify = process.env.VERIFY === "true";

  // ── network + config ────────────────────────────────────────────────────────
  const net = await ethers.provider.getNetwork();
  console.log("\n" + "=".repeat(80));
  console.log(`Network: ${net.name} (chainId: ${net.chainId})`);
  console.log("=".repeat(80));

  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = (await readJsonFile(filePath)) as Config;

  if (!config.Fundraise) {
    console.error(`\nERROR: 'Fundraise' not found in config: ${filePath}`);
    process.exit(1);
  }
  if (!config.USDC) {
    console.error(`\nERROR: 'USDC' not found in config: ${filePath}`);
    process.exit(1);
  }

  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();
  const balance = await ethers.provider.getBalance(deployerAddr);

  console.log(`\nDeployer:         ${deployerAddr}`);
  console.log(`Deployer balance: ${ethers.formatEther(balance)} ETH`);
  console.log(`Fundraise proxy:  ${config.Fundraise}`);
  console.log(`USDC:             ${config.USDC}`);
  console.log(`Backend signer:   ${signerAddr}`);
  console.log(`Verify:           ${verify}`);

  // ── deploy AmlEscrow implementation ────────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("Deploying AmlEscrow implementation...");
  console.log("=".repeat(80));

  const amlEscrowImpl = await ethers.deployContract("AmlEscrow");
  await amlEscrowImpl.waitForDeployment();
  const amlEscrowImplAddr = await amlEscrowImpl.getAddress();
  console.log(`AmlEscrow_impl:  ${amlEscrowImplAddr}`);

  // ── deploy EscrowFactory as UUPS proxy ──────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("Deploying EscrowFactory (UUPS proxy)...");
  console.log("=".repeat(80));

  const EscrowFactoryFactory = await hre.ethers.getContractFactory("EscrowFactory");
  const escrowFactoryProxy = await upgrades.deployProxy(
    EscrowFactoryFactory,
    [amlEscrowImplAddr, config.Fundraise, config.USDC, signerAddr],
    { kind: "uups", initializer: "initialize" }
  );
  await escrowFactoryProxy.waitForDeployment();
  const escrowFactoryAddr = await escrowFactoryProxy.getAddress();
  console.log(`EscrowFactory (proxy): ${escrowFactoryAddr}`);

  // wait a bit before querying storage slot
  await new Promise((resolve) => setTimeout(resolve, 12000));
  const escrowFactoryImplAddr =
    await upgrades.erc1967.getImplementationAddress(escrowFactoryAddr);
  console.log(`EscrowFactory_impl:    ${escrowFactoryImplAddr}`);

  // ── update config ───────────────────────────────────────────────────────────
  config.AmlEscrow_impl = amlEscrowImplAddr;
  config.EscrowFactory_impl = escrowFactoryImplAddr;
  config.EscrowFactory = escrowFactoryAddr;

  await writeJsonFile(filePath, config);

  // ── optional verification ───────────────────────────────────────────────────
  if (verify) {
    console.log("\n" + "=".repeat(80));
    console.log("Running Etherscan verification...");
    console.log("=".repeat(80));

    try {
      await hre.run("verify:verify", {
        address: amlEscrowImplAddr,
        constructorArguments: [],
      });
      console.log("AmlEscrow_impl verified.");
    } catch (err: unknown) {
      console.warn("AmlEscrow_impl verification failed:", (err as Error).message);
    }

    try {
      await hre.run("verify:verify", {
        address: escrowFactoryImplAddr,
        constructorArguments: [],
      });
      console.log("EscrowFactory_impl verified.");
    } catch (err: unknown) {
      console.warn("EscrowFactory_impl verification failed:", (err as Error).message);
    }

    try {
      await hre.run("verify:verify", {
        address: escrowFactoryAddr,
        constructorArguments: [],
      });
      console.log("EscrowFactory (proxy) verified.");
    } catch (err: unknown) {
      console.warn("EscrowFactory proxy verification failed:", (err as Error).message);
    }
  }

  // ── final summary ───────────────────────────────────────────────────────────
  console.log("\n" + "=".repeat(80));
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(80));
  console.log(`AmlEscrow_impl:      ${amlEscrowImplAddr}`);
  console.log(`EscrowFactory_impl:  ${escrowFactoryImplAddr}`);
  console.log(`EscrowFactory:       ${escrowFactoryAddr} (UUPS proxy)`);
  console.log("=".repeat(80));
  console.log(`Config updated: ${filePath}\n`);
}

main().catch((error: unknown) => {
  console.error("\nERROR:", (error as Error).message ?? error);
  process.exitCode = 1;
  process.exit(1);
});
