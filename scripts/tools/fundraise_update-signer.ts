import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../utils/helpers";
import { requireOwner } from "../utils/owner-guard";
import { requireRealNetwork } from "../utils/network-guard";

dotenv.config();

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");

  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  // Get wallet address from environment variable
  const trustSignerPrivateKey = process.env.TRUSTED_SIGNER_PRIVATE_KEY;
  if (!trustSignerPrivateKey) {
    throw new Error("Trusted signer private key not found in env");
  }
  const trustedSigner = new ethers.Wallet(trustSignerPrivateKey, ethers.provider);

  console.log("Setting trusted signer to:", trustedSigner.address);

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Get Fundraise contract
  if (!config.Fundraise) {
    console.error("❌ Error: Fundraise contract address not found in config");
    console.log("Please run deploy_fundraise.ts first");
    process.exit(1);
  }

  const Fundraise = await ethers.getContractAt("Fundraise", config.Fundraise);
  await requireOwner(config.Fundraise, "Fundraise");
  console.log("Fundraise contract address:", config.Fundraise);

  // Check current trusted signer
  const currentTrustedSigner = await Fundraise.trustedSigner();
  console.log("Current trusted signer:", currentTrustedSigner);

  if (currentTrustedSigner.toLowerCase() === trustedSigner.address.toLowerCase()) {
    console.log("✅ Trusted signer is already set to the same address");
    return;
  }

  try {
    // Set new trusted signer
    console.log("Setting new trusted signer...");
    const tx = await Fundraise.setTrustedSigner(trustedSigner.address);
    console.log("Transaction hash:", tx.hash);

    await tx.wait();
    console.log("✅ Trusted signer updated successfully!");

    // Check new trusted signer
    const newTrustedSigner = await Fundraise.trustedSigner();
    console.log("New trusted signer:", newTrustedSigner);

    // Update config
    config.trustedSigner = trustedSigner.address;
    await writeJsonFile(filePath, config);
    console.log("✅ Config updated with new trusted signer address");
  } catch (error) {
    console.error("❌ Error setting trusted signer:", error);
    process.exit(1);
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
