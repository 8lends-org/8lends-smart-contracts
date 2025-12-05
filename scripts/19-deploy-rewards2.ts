import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
import { readJsonFile, writeJsonFile } from "./helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  console.log("\nDeploying Rewards2 contract");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Check for required addresses in config
  if (!config.ManagerRegistry) {
    throw new Error("ManagerRegistry address not found in config");
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

  /*      address _managerRegistry,
        address _token,
        address _usdc,
        address _uniswapRouter */

  const Rewards2Factory = await hre.ethers.getContractFactory("Rewards2");
  const Rewards2 = await upgrades.deployProxy(
    Rewards2Factory,
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
  await Rewards2.waitForDeployment();
  console.log("Rewards2 deployed to:", await Rewards2.getAddress());

  await new Promise(resolve => setTimeout(resolve, 12000));

  const Rewards2_impl_addr = await upgrades.erc1967.getImplementationAddress(
    await Rewards2.getAddress()
  );
  console.log("Rewards2 implementation deployed to:", Rewards2_impl_addr);

  config.Rewards2 = await Rewards2.getAddress();
  config.Rewards2_impl = Rewards2_impl_addr;

  console.log("Rewards2 address:", await Rewards2.getAddress());

  await writeJsonFile(filePath, config);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
