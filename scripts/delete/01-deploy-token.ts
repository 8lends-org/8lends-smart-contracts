import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  console.log("\nDeploying Token contract");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  const TokenFactory = await hre.ethers.getContractFactory("Token");
  const Token = await TokenFactory.deploy();
  await Token.waitForDeployment();
  console.log("Token deployed to:", await Token.getAddress());

  config.token = await Token.getAddress();

  console.log("\n✅ Token successfully deployed");
  console.log("Token address:", await Token.getAddress());
  console.log("⚠️  Note: ManagerRegistry must be set later using setManagerRegistry()");

  await writeJsonFile(filePath, config);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
