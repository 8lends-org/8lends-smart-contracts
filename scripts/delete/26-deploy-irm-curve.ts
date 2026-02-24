import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../helpers";

dotenv.config();

async function main(): Promise<void> {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  const lending8Address = (config as Record<string, string>).Lending8;
  if (!lending8Address) {
    throw new Error("Lending8 address not found in config");
  }

  console.log("Deploying AdaptiveCurveIrm contract");

  const [signer] = await ethers.getSigners();
  const owner = await signer.getAddress();
  console.log("Owner:", owner);

  const balance = await ethers.provider.getBalance(owner);
  console.log("Owner native balance:", ethers.formatEther(balance));

  const AdaptiveCurveIrmFactory = await hre.ethers.getContractFactory("AdaptiveCurveIrm");
  const AdaptiveCurveIrm = await AdaptiveCurveIrmFactory.deploy(lending8Address);
  await AdaptiveCurveIrm.waitForDeployment();
  const irmAddress = await AdaptiveCurveIrm.getAddress();
  console.log("AdaptiveCurveIrm deployed to:", irmAddress);

  (config as Record<string, string>).AdaptiveCurveIrm = irmAddress;
  await writeJsonFile(filePath, config);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
