import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../utils/helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  console.log(`\nNetwork name: ${net.name}\n`);

  const config = await readJsonFile(`./scripts/config/${net.chainId}-config.json`);

  // Get wallet address from environment variable or use default
  const walletAddress = process.env.WALLET_ADDRESS || (await ethers.getSigners())[0].address;

  if (!walletAddress) {
    console.log(
      "Usage: WALLET_ADDRESS=0x123... npx hardhat run scripts/check_balance.ts --network <network>"
    );
    console.log(
      "Example: WALLET_ADDRESS=0x123... npx hardhat run scripts/check_balance.ts --network base_sepolia"
    );
    process.exit(1);
  }

  // Validate wallet address
  if (!ethers.isAddress(walletAddress)) {
    throw new Error("Invalid wallet address");
  }

  console.log(`Checking balances for address: ${walletAddress}\n`);

  // Check native balance (ETH/BNB/etc.)
  const nativeBalance = await ethers.provider.getBalance(walletAddress);
  console.log(`Native balance: ${ethers.formatEther(nativeBalance)} "ETH"`);

  // Check testToken balance (USDC)
  if (config.testUsdt) {
    try {
      const testToken = await ethers.getContractAt("MockERC20", config.testUsdt);
      const testTokenBalance = await testToken.balanceOf(walletAddress);
      const testTokenSymbol = await testToken.symbol();
      const testTokenDecimals = await testToken.decimals();
      console.log(
        `${testTokenSymbol} balance: ${ethers.formatUnits(testTokenBalance, testTokenDecimals)}`
      );
    } catch (error: any) {
      console.log("Could not check testToken balance:", error.message);
    }
  }

  // Check Token balance
  if (config.token) {
    try {
      const token = await ethers.getContractAt("Token", config.token);
      const tokenBalance = await token.balanceOf(walletAddress);
      const tokenSymbol = await token.symbol();
      const tokenDecimals = await token.decimals();
      console.log(`${tokenSymbol} balance: ${ethers.formatUnits(tokenBalance, tokenDecimals)}`);
    } catch (error: any) {
      console.log("Could not check Token balance:", error.message);
    }
  }

  // Check USDC balance (if different from testUsdt)
  if (config.usdc && config.usdc !== config.testUsdt) {
    try {
      const usdcToken = await ethers.getContractAt("MockERC20", config.usdc);
      const usdcBalance = await usdcToken.balanceOf(walletAddress);
      const usdcSymbol = await usdcToken.symbol();
      const usdcDecimals = await usdcToken.decimals();
      console.log(`${usdcSymbol} balance: ${ethers.formatUnits(usdcBalance, usdcDecimals)}`);
    } catch (error: any) {
      console.log("Could not check USDC balance:", error.message);
    }
  }

  console.log("\n✅ Balance check completed!");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
