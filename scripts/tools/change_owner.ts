import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../utils/helpers";
import { HDNodeWallet, Mnemonic } from "ethers";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");

  // Generate new wallet
  console.log("🔐 Generating new wallet...");
  const newWallet = HDNodeWallet.createRandom();

  const newAddress = newWallet.address;
  const newPrivateKey = newWallet.privateKey;
  const newMnemonic = newWallet.mnemonic?.phrase || "";

  console.log("\n" + "=".repeat(80));
  console.log("🚨 IMPORTANT! SAVE THIS DATA IN A SAFE PLACE! 🚨");
  console.log("=".repeat(80));
  console.log("📧 New address:", newAddress);
  console.log("🔑 Private key:", newPrivateKey);
  console.log("📝 Mnemonic:", newMnemonic);
  console.log("=".repeat(80));
  console.log("⚠️  DO NOT LOSE THIS DATA! WITHOUT IT YOU CANNOT ACCESS YOUR FUNDS! ⚠️");
  console.log("=".repeat(80) + "\n");

  // Get current signer
  const [currentSigner] = await ethers.getSigners();
  const currentAddress = await currentSigner.getAddress();

  console.log("Current address:", currentAddress);
  console.log("New address:", newAddress);

  // Get balances
  const ethBalance = await ethers.provider.getBalance(currentAddress);
  console.log("ETH balance:", ethers.formatEther(ethBalance));

  // Load config to get USDC address
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  if (!config.USDC) {
    throw new Error("USDC address not found in config");
  }

  console.log("USDC address:", config.USDC);

  // Get USDC contract
  const usdcContract = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.USDC);
  const usdcBalance = await usdcContract.balanceOf(currentAddress);
  console.log("USDC balance:", ethers.formatUnits(usdcBalance, 6));

  // Check if there is anything to transfer
  if (ethBalance === 0n && usdcBalance === 0n) {
    console.log("❌ No funds to transfer");
    return;
  }

  // Estimate gas for transactions
  const gasPrice = await ethers.provider.getFeeData();
  const gasPriceWei = gasPrice.gasPrice || ethers.parseUnits("20", "gwei");

  // Estimate gas for USDC transfer (approve + transfer)
  const usdcTransferGas = 21000n + 50000n; // base transaction + approve
  const ethTransferGas = 21000n; // base transaction

  const totalGasCost = (usdcTransferGas + ethTransferGas) * gasPriceWei;
  const gasCostEth = ethers.formatEther(totalGasCost);

  console.log("💰 Estimated gas cost:", gasCostEth, "ETH");

  // Check if there is enough ETH for gas
  if (ethBalance < totalGasCost) {
    console.log("❌ Not enough ETH to cover gas");
    return;
  }

  // Calculate ETH amount to transfer (full balance minus gas)
  const ethToTransfer = ethBalance - totalGasCost;

  console.log("\n📤 Transferring funds...");
  console.log("USDC to transfer:", ethers.formatUnits(usdcBalance, 6));
  console.log("ETH to transfer:", ethers.formatEther(ethToTransfer));

  // Transfer USDC
  if (usdcBalance > 0n) {
    console.log("\n🔄 Transfer USDC...");
    const usdcTransferTx = await usdcContract.transfer(newAddress, usdcBalance);
    console.log("USDC transaction:", usdcTransferTx.hash);
    await usdcTransferTx.wait(5);
    console.log("✅ USDC transferred");
  }

  // Transfer ETH
  if (ethToTransfer > 0n) {
    console.log("\n🔄 Transfer ETH...");
    const ethTransferTx = await currentSigner.sendTransaction({
      to: newAddress,
      value: ethToTransfer,
    });
    console.log("ETH transaction:", ethTransferTx.hash);
    await ethTransferTx.wait(5);
    console.log("✅ ETH transferred");
  }

  // Check final balances
  console.log("\n📊 Final balances:");

  const finalEthBalance = await ethers.provider.getBalance(newAddress);
  const finalUsdcBalance = await usdcContract.balanceOf(newAddress);

  console.log("New address ETH:", ethers.formatEther(finalEthBalance));
  console.log("New address USDC:", ethers.formatUnits(finalUsdcBalance, 6));

  const remainingEthBalance = await ethers.provider.getBalance(currentAddress);
  const remainingUsdcBalance = await usdcContract.balanceOf(currentAddress);

  console.log("Old address ETH:", ethers.formatEther(remainingEthBalance));
  console.log("Old address USDC:", ethers.formatUnits(remainingUsdcBalance, 6));

  // Save data to file for security
  const walletData = {
    address: newAddress,
    privateKey: newPrivateKey,
    mnemonic: newMnemonic,
    network: net.name,
    chainId: net.chainId.toString(),
    createdAt: new Date().toISOString(),
    transferredEth: ethers.formatEther(ethToTransfer),
    transferredUsdc: ethers.formatUnits(usdcBalance, 6),
  };

  const fileName = `wallet_${newAddress.slice(2, 8)}_${Date.now()}.json`;
  fs.writeFileSync(fileName, JSON.stringify(walletData, null, 2));

  console.log("\n💾 Wallet data saved to file:", fileName);
  console.log("🔒 Be sure to save this file in a safe place!");

  console.log("\n🎉 Transfer completed successfully!");
  console.log("📋 New owner:", newAddress);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error("❌ Error:", error);
    process.exit(1);
  });
