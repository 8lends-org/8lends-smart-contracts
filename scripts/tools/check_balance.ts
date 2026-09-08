import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../utils/helpers";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log(`\nNetwork name: ${net.name}\n`);

  const config = await readJsonFile(`./scripts/config/${net.chainId}-config.json`);

  // Get wallet address from environment variable or use default
  const walletAddress = process.env.WALLET_ADDRESS || (await ethers.getSigners())[0].address;

  if (!walletAddress) {
    console.log(
      "Usage: WALLET_ADDRESS=0x123... npx hardhat run scripts/tools/check_balance.ts --network <network>"
    );
    console.log(
      "Example: WALLET_ADDRESS=0x123... npx hardhat run scripts/tools/check_balance.ts --network sepolia"
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

  // USDC: real on Base, the mintable stand-in on Sepolia — same config key either way
  if (config.USDC) {
    try {
      const usdcToken = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol:IERC20Metadata", config.USDC as string);
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
