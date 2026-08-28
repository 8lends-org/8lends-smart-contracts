import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../utils/helpers";
import { requireOwner } from "../utils/owner-guard";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

async function main() {
  requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  console.log(`\nSetting pool status in ManagerRegistry...`);
  console.log(`Network: ${net.name} (Chain ID: ${net.chainId})`);

  const [signer] = await ethers.getSigners();
  console.log(`Signer: ${await signer.getAddress()}`);

  // Get contract addresses from configuration
  const managerRegistryAddress = config.ManagerRegistry;
  const POOL_ADDRESS = process.env.POOL_ADDRESS;

  if (!managerRegistryAddress) {
    throw new Error("ManagerRegistry contract not found in config");
  }

  if (!POOL_ADDRESS) {
    throw new Error("Pool contract not found in env");
  }

  console.log(`\nContract addresses:`);
  console.log(`ManagerRegistry: ${managerRegistryAddress}`);
  console.log(`Pool: ${POOL_ADDRESS}`);

  // Connect to ManagerRegistry contract
  const managerRegistry = await ethers.getContractAt("ManagerRegistry", managerRegistryAddress);

  // Check owner rights
  await requireOwner(config.ManagerRegistry as string, "ManagerRegistry");

  // Check current pool status
  const currentPoolStatus = await managerRegistry.pools(POOL_ADDRESS);
  console.log(`Current pool status: ${currentPoolStatus}`);

  if (currentPoolStatus) {
    console.log(`✅ Pool is already enabled`);
    return;
  }

  console.log(`\nSetting pool status to enabled...`);

  // Call setPoolStatus method
  const tx = await managerRegistry.setPoolStatus(POOL_ADDRESS, true);

  console.log(`Transaction hash: ${tx.hash}`);
  console.log(`Waiting for confirmation...`);

  const receipt = await tx.wait(5);
  console.log(`✅ Pool status updated successfully!`);
  console.log(`Gas used: ${receipt?.gasUsed.toString()}`);

  // Check that status is set correctly
  const newPoolStatus = await managerRegistry.pools(POOL_ADDRESS);
  console.log(`New pool status: ${newPoolStatus}`);

  if (newPoolStatus) {
    console.log(`✅ Pool status verified successfully!`);
  } else {
    throw new Error("Pool status verification failed");
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
