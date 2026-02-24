import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
import { readJsonFile, writeJsonFile } from "../helpers";

dotenv.config();

async function main(): Promise<void> {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  console.log("Deploying Lending8 contract (upgradeable proxy)");

  const [signer] = await ethers.getSigners();
  const owner = await signer.getAddress();
  console.log("Owner:", owner);

  const balance = await ethers.provider.getBalance(owner);
  console.log("Owner native balance:", ethers.formatEther(balance));

  const Lending8Factory = await hre.ethers.getContractFactory("Lending8");
  const Lending8 = await upgrades.deployProxy(Lending8Factory, [owner], {
    kind: "uups",
    initializer: "initialize",
  });
  await Lending8.waitForDeployment();
  const lending8Address = await Lending8.getAddress();
  console.log("Lending8 (proxy) deployed to:", lending8Address);

  await new Promise(resolve => setTimeout(resolve, 12000));

  const lending8ImplAddress = await upgrades.erc1967.getImplementationAddress(lending8Address);
  console.log("Lending8 implementation:", lending8ImplAddress);

  (config as Record<string, string>).Lending8 = lending8Address;
  (config as Record<string, string>).Lending8_impl = lending8ImplAddress;
  await writeJsonFile(filePath, config);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
