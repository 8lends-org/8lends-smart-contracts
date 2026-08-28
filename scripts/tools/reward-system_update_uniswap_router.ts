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
  await writeJsonFile(filePath, config);

  console.log("✅ Config updated with new Uniswap router address");
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
