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

  console.log("\nDeploying Threasury contract");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  const TreasuryFactory = await hre.ethers.getContractFactory("Treasury");
  const Treasury = await upgrades.deployProxy(TreasuryFactory, [], {
    kind: "uups",
    initializer: "initialize",
  });
  await Treasury.waitForDeployment();
  console.log("Treasury deployed to:", await Treasury.getAddress());

  await new Promise(resolve => setTimeout(resolve, 12000));

  const Treasury_impl_addr = await upgrades.erc1967.getImplementationAddress(
    await Treasury.getAddress()
  );
  console.log("Treasury implementation deployed to:", Treasury_impl_addr);

  config.Treasury = await Treasury.getAddress();
  config.Treasury_impl = Treasury_impl_addr;

  await writeJsonFile(filePath, config);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
