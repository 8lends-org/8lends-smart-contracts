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

  console.log("\nDeploying Manager Registry contract");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  if (!config.ManagerRegistry) {
    const ManagerRegistryFactory = await hre.ethers.getContractFactory("ManagerRegistry");
    const ManagerRegistry = await upgrades.deployProxy(ManagerRegistryFactory, [], {
      kind: "uups",
      initializer: "initialize",
    });
    await ManagerRegistry.waitForDeployment();
    console.log("ManagerRegistry deployed to:", await ManagerRegistry.getAddress());
    config.ManagerRegistry = await ManagerRegistry.getAddress();
    await writeJsonFile(filePath, config);
  } else console.log("ManagerRegistry already deployed to:", config.ManagerRegistry);

  await new Promise(resolve => setTimeout(resolve, 12000));

  if (!config.ManagerRegistry_impl) {
    const ManagerRegistry_impl_addr = await upgrades.erc1967.getImplementationAddress(
      config.ManagerRegistry
    );
    console.log("ManagerRegistry implementation deployed to:", ManagerRegistry_impl_addr);
    config.ManagerRegistry_impl = ManagerRegistry_impl_addr;
    await writeJsonFile(filePath, config);
  } else
    console.log("ManagerRegistry implementation already deployed to:", config.ManagerRegistry_impl);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
