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

  console.log("\nDeploying Market contract");

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

  const MarketFactory = await hre.ethers.getContractFactory("Market");
  const Market = await upgrades.deployProxy(
    MarketFactory,
    [config.ManagerRegistry],
    {
      kind: "uups",
      initializer: "initialize",
    }
  );
  await Market.waitForDeployment();
  console.log("Market deployed to:", await Market.getAddress());

  await new Promise(resolve => setTimeout(resolve, 12000));

  const Market_impl_addr = await upgrades.erc1967.getImplementationAddress(
    await Market.getAddress()
  );
  console.log("Market implementation deployed to:", Market_impl_addr);

  config.Market = await Market.getAddress();
  config.Market_impl = Market_impl_addr;

  console.log("Market address:", await Market.getAddress());

  await writeJsonFile(filePath, config);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
