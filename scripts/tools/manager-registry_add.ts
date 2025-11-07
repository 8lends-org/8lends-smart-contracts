import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");

  const MANAGERS_ADDRESSES = process.env.MANAGERS_ADDRESSES;
  if (!MANAGERS_ADDRESSES) {
    throw new Error("MANAGERS_ADDRESSES not found in env");
  }
  const managersAddresses = MANAGERS_ADDRESSES.split(",").map(addr => addr.trim());
  console.log("Wallets addresses:", managersAddresses);
  if (managersAddresses.length === 0) {
    throw new Error("No MANAGERS_ADDRESSES found in env");
  }

  // Load network configuration
  let configPath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(configPath);

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Check that ManagerRegistry is deployed
  if (!config.ManagerRegistry) {
    throw new Error("ManagerRegistry not found in config. Please deploy it first.");
  }

  console.log("ManagerRegistry address:", config.ManagerRegistry);

  // Connect to contract
  const ManagerRegistry = await ethers.getContractAt("ManagerRegistry", config.ManagerRegistry);

  // Create array of statuses (all true)
  const statuses = new Array(managersAddresses.length).fill(true);

  console.log("Adding managers to ManagerRegistry...");

  const nonce = await ethers.provider.getTransactionCount(await signer.getAddress());
  console.log("Nonce:", nonce);

  // Add managers in batch
  const tx = await ManagerRegistry.setManagerStatusBatch(managersAddresses, statuses, { nonce });
  console.log("Transaction hash:", tx.hash);

  await tx.wait();
  console.log("Managers added successfully!");

  // Check that managers are added
  for (const address of managersAddresses) {
    const isManager = await ManagerRegistry.isManager(address);
    console.log(`Manager ${address}: ${isManager ? "✓" : "✗"}`);
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
