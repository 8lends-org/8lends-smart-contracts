import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../utils/helpers";
import { requireOwner } from "../utils/owner-guard";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log(`\nNetwork name: ${net.name}\n`);

  const TO_WALLET_ADDRESS = process.env.TO_WALLET_ADDRESS;
  const AMOUNT = process.env.AMOUNT;

  const config = await readJsonFile(`./scripts/config/${net.chainId}-config.json`);

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Check if USDC address exists in config
  const tokenAddress = config.testUsdt || config.usdc;
  if (!tokenAddress) {
    throw new Error("USDC/testUsdt address not found in config");
  }

  console.log("Token address:", tokenAddress);

  // Connect to Token contract
  const testToken = await ethers.getContractAt("MockERC20", tokenAddress);
  await requireOwner(tokenAddress, "USDC (test token)");

  // Get parameters from environment variables

  if (!TO_WALLET_ADDRESS || !AMOUNT) {
    console.log(
      "Usage: TO_WALLET_ADDRESS=0x123... AMOUNT=1000 npx hardhat run scripts/mint_test_token.ts --network <network>"
    );
    console.log(
      "Example: TO_WALLET_ADDRESS=0x123... AMOUNT=1000 npx hardhat run scripts/mint_test_token.ts --network base_sepolia"
    );
    process.exit(1);
  }

  // Validate wallet address
  if (!ethers.isAddress(TO_WALLET_ADDRESS)) {
    throw new Error("Invalid wallet address");
  }

  // Validate amount (should be a positive number)
  const mintAmount = ethers.parseUnits(AMOUNT, 6); // Assuming 6 decimals for USDC
  if (mintAmount <= 0) {
    throw new Error("Amount must be positive");
  }

  console.log(`\nMinting ${AMOUNT} test tokens to ${TO_WALLET_ADDRESS}...`);

  // Mint tokens
  const mintTx = await testToken.mint(TO_WALLET_ADDRESS, mintAmount);
  console.log("Transaction hash:", mintTx.hash);

  await mintTx.wait();
  console.log("✅ Tokens minted successfully!");

  // Check balance
  const balance = await testToken.balanceOf(TO_WALLET_ADDRESS);
  console.log(`New balance: ${ethers.formatUnits(balance, 6)} test tokens`);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
