import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "../helpers";
dotenv.config();

async function main() {
  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  console.log(`\nUpdating contract addresses in ManagerRegistry...`);
  console.log(`Network: ${net.name} (Chain ID: ${net.chainId})`);

  const [signer] = await ethers.getSigners();
  console.log(`Signer: ${await signer.getAddress()}`);

  // Get contract addresses from configuration
  const managerRegistryAddress = config.ManagerRegistry;
  const rewardSystemAddress = config.RewardSystem;
  const fundraiseAddress = config.Fundraise;
  const treasuryAddress = config.Treasury;
  const poolAddress = config.pool;
  const tokenAddress = config.token;
  const marketAddress = config.Market;

  if (!managerRegistryAddress) {
    throw new Error("ManagerRegistry contract not found in config");
  }

  if (!rewardSystemAddress) {
    throw new Error("RewardSystem contract not found in config");
  }

  if (!fundraiseAddress) {
    throw new Error("Fundraise contract not found in config");
  }

  if (!treasuryAddress) {
    throw new Error("Treasury contract not found in config");
  }

  if (!marketAddress) {
    throw new Error("Market contract not found in config");
  }

  console.log(`\nContract addresses:`);
  console.log(`ManagerRegistry: ${managerRegistryAddress}`);
  console.log(`RewardSystem: ${rewardSystemAddress}`);
  console.log(`Fundraise: ${fundraiseAddress}`);
  console.log(`Treasury: ${treasuryAddress}`);
  console.log(`Token: ${tokenAddress}`);
  console.log(`Pool: ${poolAddress}`);
  console.log(`Market: ${marketAddress}`);

  // Connect to ManagerRegistry contract
  const managerRegistry = await ethers.getContractAt("ManagerRegistry", managerRegistryAddress);

  // Check owner rights
  const owner = await managerRegistry.owner();
  if (owner.toLowerCase() !== (await signer.getAddress()).toLowerCase()) {
    throw new Error("Not the owner of ManagerRegistry contract");
  }

  console.log(`\nChecking current contract addresses...`);

  // Check current addresses
  const currentMarketAddress = await managerRegistry.marketAddress();
  const currentRewardSystem = await managerRegistry.rewardSystemAddress();
  const currentFundraise = await managerRegistry.fundraiseAddress();
  const currentTreasury = await managerRegistry.treasuryAddress();

  // Check and update Market address if needed
  if (currentMarketAddress.toLowerCase() !== marketAddress.toLowerCase()) {
    console.log(`\nUpdating Market address...`);
    console.log(`Current: ${currentMarketAddress}`);
    console.log(`New: ${marketAddress}`);
    const marketTx = await managerRegistry.setMarketAddress(marketAddress);
    console.log(`Market transaction hash: ${marketTx.hash}`);
    await marketTx.wait(5);
    console.log(`✅ Market address set successfully!`);
  } else {
    console.log(`ℹ️  Market address already correct, skipping update`);
  }

  // Check and update contract addresses if needed
  const needsUpdate = 
    currentRewardSystem.toLowerCase() !== rewardSystemAddress.toLowerCase() ||
    currentFundraise.toLowerCase() !== fundraiseAddress.toLowerCase() ||
    currentTreasury.toLowerCase() !== treasuryAddress.toLowerCase();

  if (needsUpdate) {
    console.log(`\nUpdating contract addresses (some are different)...`);
    console.log(`Current RewardSystem: ${currentRewardSystem}`);
    console.log(`New RewardSystem: ${rewardSystemAddress}`);
    console.log(`Current Fundraise: ${currentFundraise}`);
    console.log(`New Fundraise: ${fundraiseAddress}`);
    console.log(`Current Treasury: ${currentTreasury}`);
    console.log(`New Treasury: ${treasuryAddress}`);

    // Call setContractAddresses method
    const tx = await managerRegistry.setContractAddresses(
      rewardSystemAddress,
      fundraiseAddress,
      treasuryAddress
    );

    console.log(`Transaction hash: ${tx.hash}`);
    console.log(`Waiting for confirmation...`);

    const receipt = await tx.wait(5);
    console.log(`✅ Contract addresses updated successfully!`);
    console.log(`Gas used: ${receipt?.gasUsed.toString()}`);
  } else {
    console.log(`ℹ️  All contract addresses are already correct, skipping update`);
  }

  // Verify addresses after update (re-read after potential updates)
  console.log(`\nVerifying addresses...`);
  const verifiedRewardSystem = await managerRegistry.rewardSystemAddress();
  const verifiedFundraise = await managerRegistry.fundraiseAddress();
  const verifiedTreasury = await managerRegistry.treasuryAddress();

  console.log(`Current RewardSystem: ${verifiedRewardSystem}`);
  console.log(`Current Fundraise: ${verifiedFundraise}`);
  console.log(`Current Treasury: ${verifiedTreasury}`);

  // Check correspondence
  if (verifiedRewardSystem.toLowerCase() !== rewardSystemAddress.toLowerCase()) {
    throw new Error("RewardSystem address mismatch");
  }
  if (verifiedFundraise.toLowerCase() !== fundraiseAddress.toLowerCase()) {
    throw new Error("Fundraise address mismatch");
  }
  if (verifiedTreasury.toLowerCase() !== treasuryAddress.toLowerCase()) {
    throw new Error("Treasury address mismatch");
  }

}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
