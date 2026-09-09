import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { requireOwner } from "../utils/owner-guard";
import { requireRealNetwork } from "../utils/network-guard";
import { loadConfig, saveConfig } from "../utils/config";

dotenv.config();

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  const config = loadConfig(net.chainId);

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
  saveConfig(net.chainId, config);

  console.log("✅ Config updated with new Token address");
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
