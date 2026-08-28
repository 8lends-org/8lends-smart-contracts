import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../utils/helpers";
import { requireOwner } from "../utils/owner-guard";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log(`\nNetwork name: ${net.name}\n`);

  const config = await readJsonFile(`./scripts/config/${net.chainId}-config.json`);

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Check if token address exists in config
  if (!config.token) {
    throw new Error("Token address not found in config");
  }

  console.log("Token address:", config.token);

  const TO_ADDRESS = process.env.TO_ADDRESS;
  const AMOUNT = process.env.AMOUNT;
  if (!TO_ADDRESS || !AMOUNT) {
    throw new Error("TO_ADDRESS or AMOUNT not found in env");
  }
  // Connect to Token contract
  const token = await ethers.getContractAt("Token", config.token);
  await requireOwner(config.token, "Token");

  // Get command line arguments

  // Validate wallet address
  if (!ethers.isAddress(TO_ADDRESS)) {
    throw new Error("Invalid wallet address");
  }

  // Validate amount (should be a positive number)
  const mintAmount = ethers.parseEther(AMOUNT); // Token has 18 decimals
  if (mintAmount <= 0) {
    throw new Error("Amount must be positive");
  }

  console.log(`\nMinting ${AMOUNT} TOKEN1111 to ${TO_ADDRESS}...`);

  // Mint tokens
  const mintTx = await token.mint(TO_ADDRESS, mintAmount);
  console.log("Transaction hash:", mintTx.hash);

  await mintTx.wait();
  console.log("✅ TOKEN1111 minted successfully!");

  // Check balance
  const balance = await token.balanceOf(TO_ADDRESS);
  console.log(`New balance: ${ethers.formatEther(balance)} TOKEN1111`);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
