import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";

dotenv.config();

// Read percentage from environment variable
const PERCENT = process.env.PERCENT;

/**
 * Script for setting additional unlock percentage for sell operations.
 * 
 * Usage: PERCENT=26 npx hardhat run scripts/set-additional-unlock-percentage.ts --network base
 * 
 * This sets the global additional unlock percentage that users can access
 * when using claimAndSellTokensForProjectBatch function.
 */
async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    console.log("🌐 Network:", net.name, `(Chain ID: ${net.chainId})`);

    const config: {
        uniswapV2Router: string;
        usdc: string;
        token: string;
        RewardSystem: string;
        Rewards2: string;
    } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

    if (!PERCENT) {
        throw new Error("❌ PERCENT is not set. Usage: PERCENT=26 npx hardhat run scripts/set-additional-unlock-percentage.ts");
    }

    if (!config.RewardSystem) {
        throw new Error("❌ RewardSystem address is not set in config");
    }

    const [signer] = await ethers.getSigners();
    console.log("👤 Signer:", await signer.getAddress());

    // Convert percentage to BASIS_POINTS (1% = 10000)
    const percentValue = parseFloat(PERCENT);
    if (isNaN(percentValue) || percentValue < 0 || percentValue > 100) {
        throw new Error("❌ PERCENT must be a number between 0 and 100");
    }

    const percentageInBasisPoints = Math.floor(percentValue * 10000);
    
    console.log("\n📊 Setting additional unlock percentage:");
    console.log(`   Percentage: ${percentValue}%`);
    console.log(`   Basis Points: ${percentageInBasisPoints}`);
    console.log(`   RewardSystem: ${config.RewardSystem}`);

    const CONTRACT_ABI = readFileSync(join(__dirname, "../abis/RewardSystem.json"), "utf8");
    const rewardSystem = new ethers.Contract(config.RewardSystem, CONTRACT_ABI, signer);

    // Get current value
    const currentPercentage = await rewardSystem.additionalUnlockPercentage();
    const currentPercent = Number(currentPercentage) / 10000;
    console.log(`\n📌 Current additional unlock: ${currentPercent}%`);

    if (currentPercentage.toString() === percentageInBasisPoints.toString()) {
        console.log("⚠️  Value is already set to this percentage. Skipping...");
        return;
    }

    // Set new value
    console.log(`\n⏳ Setting additional unlock to ${percentValue}%...`);
    const tx = await rewardSystem.setAdditionalUnlock(percentageInBasisPoints);
    console.log(`   Transaction sent: ${tx.hash}`);
    
    await tx.wait();
    console.log(`   ✅ Transaction confirmed`);

    // Verify new value
    const newPercentage = await rewardSystem.additionalUnlockPercentage();
    const newPercent = Number(newPercentage) / 10000;
    console.log(`\n✅ Additional unlock updated successfully!`);
    console.log(`   Old: ${currentPercent}%`);
    console.log(`   New: ${newPercent}%`);

    console.log("\n💡 Note: This affects all users who use claimAndSellTokensForProjectBatch");
    console.log("   Users who already claimed with a higher percentage are protected.");
}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});

