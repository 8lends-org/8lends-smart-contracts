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

  console.log("Deploying Oracle contract (upgradeable proxy)");

  const [signer] = await ethers.getSigners();
  const owner = await signer.getAddress();
  console.log("Owner:", owner);

  const balance = await ethers.provider.getBalance(owner);
  console.log("Owner native balance:", ethers.formatEther(balance));

  const OracleFactory = await hre.ethers.getContractFactory("Oracle");
  const Oracle = await upgrades.deployProxy(OracleFactory, [owner], {
    kind: "uups",
    initializer: "initialize",
  });
  await Oracle.waitForDeployment();
  const oracleAddress = await Oracle.getAddress();
  console.log("Oracle (proxy) deployed to:", oracleAddress);

  await new Promise(resolve => setTimeout(resolve, 12000));

  const oracleImplAddress = await upgrades.erc1967.getImplementationAddress(oracleAddress);
  console.log("Oracle implementation:", oracleImplAddress);

  (config as Record<string, string>).Oracle = oracleAddress;
  (config as Record<string, string>).Oracle_impl = oracleImplAddress;
  await writeJsonFile(filePath, config);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
