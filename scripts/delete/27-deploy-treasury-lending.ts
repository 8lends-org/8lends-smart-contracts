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

  console.log("Deploying TreasuryLending contract (upgradeable proxy)");

  const [signer] = await ethers.getSigners();
  const owner = await signer.getAddress();
  console.log("Owner:", owner);

  const balance = await ethers.provider.getBalance(owner);
  console.log("Owner native balance:", ethers.formatEther(balance));

  const TreasuryLendingFactory = await hre.ethers.getContractFactory("TreasuryLending");
  const TreasuryLending = await upgrades.deployProxy(TreasuryLendingFactory, [], {
    kind: "uups",
    initializer: "initialize",
  });
  await TreasuryLending.waitForDeployment();
  const treasuryLendingAddress = await TreasuryLending.getAddress();
  console.log("TreasuryLending (proxy) deployed to:", treasuryLendingAddress);

  await new Promise(resolve => setTimeout(resolve, 12000));

  const treasuryLendingImplAddress = await upgrades.erc1967.getImplementationAddress(treasuryLendingAddress);
  console.log("TreasuryLending implementation:", treasuryLendingImplAddress);

  (config as Record<string, string>).TreasuryLending = treasuryLendingAddress;
  (config as Record<string, string>).TreasuryLending_impl = treasuryLendingImplAddress;
  await writeJsonFile(filePath, config);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
