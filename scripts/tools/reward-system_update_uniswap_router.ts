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

  console.log("\nUpdating Uniswap router in RewardSystem...");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  // Check for RewardSystem in config
  if (!config.RewardSystem) {
    throw new Error("RewardSystem address not found in config");
  }

  // Get new Uniswap router address from environment variable
  const newUniswapRouter = process.env.UNISWAP_ROUTER;
  if (!newUniswapRouter) {
    throw new Error("UNISWAP_ROUTER environment variable not set");
  }

  const currentUniswapRouter = config.uniswapV2Router;
  console.log("Current Uniswap router:", currentUniswapRouter);
  console.log("New Uniswap router:", newUniswapRouter);

  // Connect to RewardSystem contract
  const rewardSystem = await ethers.getContractAt("RewardSystem", config.RewardSystem);

  // Check owner rights
  await requireOwner(config.RewardSystem as string, "RewardSystem");

  // Update Uniswap router
  console.log("Updating Uniswap router...");
  const tx = await rewardSystem.updateUniswapRouterAddress(newUniswapRouter);
  await tx.wait();

  console.log("✅ Uniswap router updated successfully!");
  console.log("Transaction hash:", tx.hash);

  // Update config
  config.uniswapV2Router = newUniswapRouter;
  saveConfig(net.chainId, config);

  console.log("✅ Config updated with new Uniswap router address");
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
