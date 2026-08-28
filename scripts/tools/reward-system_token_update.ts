import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../utils/helpers";
import { requireOwner } from "../utils/owner-guard";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

async function main() {
  requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  console.log("\nUpdating Token address in RewardSystem...");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  // Check for RewardSystem in config
  if (!config.RewardSystem) {
    throw new Error("RewardSystem address not found in config");
  }

  // Get new token address from environment variable
  const newToken = process.env.NEW_TOKEN_ADDRESS;
  if (!newToken) {
    throw new Error("NEW_TOKEN_ADDRESS environment variable not set");
  }

  const currentToken = config.token;
  console.log("Current Token address:", currentToken);
  console.log("New Token address:", newToken);

  // Connect to RewardSystem contract
  const rewardSystem = await ethers.getContractAt("RewardSystem", config.RewardSystem);

  // Check owner rights
  await requireOwner(config.RewardSystem as string, "RewardSystem");

  // Update token address
  console.log("Updating Token address...");
  const tx = await rewardSystem.updateTokenAddress(newToken);
  await tx.wait();

  console.log("✅ Token address updated successfully!");
  console.log("Transaction hash:", tx.hash);

  // Update config
  config.token = newToken;
  await writeJsonFile(filePath, config);

  console.log("✅ Config updated with new Token address");
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
