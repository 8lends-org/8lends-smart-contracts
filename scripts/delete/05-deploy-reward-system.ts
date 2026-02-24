import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
import { readJsonFile, writeJsonFile } from "../helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  console.log("\nDeploying RewardSystem contract");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Check for required addresses in config
  if (!config.ManagerRegistry) {
    throw new Error("ManagerRegistry address not found in config");
  }
  if (!config.Treasury) {
    throw new Error("Treasury address not found in config");
  }
  if (!config.usdc) {
    throw new Error("USDC address not found in config");
  }
  if (!config.uniswapV2Router) {
    throw new Error("UniswapV2Router not found in config");
  }
  if (!config.token) {
    throw new Error("Token not found in config");
  }

  const RewardSystemFactory = await hre.ethers.getContractFactory("RewardSystem");
  const RewardSystem = await upgrades.deployProxy(
    RewardSystemFactory,
    [
      config.ManagerRegistry,
      config.token, // Placeholder, needs to be updated
      config.usdc, // USDC
      config.uniswapV2Router, // UniswapV2Router02 on Base testnet
    ],
    {
      kind: "uups",
      initializer: "initialize",
    }
  );
  await RewardSystem.waitForDeployment();
  console.log("RewardSystem deployed to:", await RewardSystem.getAddress());

  await new Promise(resolve => setTimeout(resolve, 12000));

  const RewardSystem_impl_addr = await upgrades.erc1967.getImplementationAddress(
    await RewardSystem.getAddress()
  );
  console.log("RewardSystem implementation deployed to:", RewardSystem_impl_addr);

  config.RewardSystem = await RewardSystem.getAddress();
  config.RewardSystem_impl = RewardSystem_impl_addr;

  console.log("RewardSystem address:", await RewardSystem.getAddress());

  await writeJsonFile(filePath, config);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
