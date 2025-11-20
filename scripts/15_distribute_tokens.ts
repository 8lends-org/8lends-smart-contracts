import dotenv from "dotenv";
import { ethers } from "hardhat";
import fs from "fs";
import path from "path";
import { readJsonFile } from "./helpers";

dotenv.config();

/**
 * Distribution script for immediate token rewards (NO VESTING)
 * 
 * This script distributes tokens directly to users via RewardSystem.distributeTokens()
 * Tokens are sent immediately without vesting schedule.
 * 
 * Number of addresses in one batch to avoid gas limit issues
 */
const BATCH_SIZE = 500;

interface WalletDistribution {
    wallet: string;
    investedUSDCAmount: number;
    rewardUSDAmount: number;
}

/**
 * Main function to distribute tokens immediately (without vesting) to wallet distributions.
 */
async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    const filePath = `./scripts/config/${net.chainId}-config.json`;
    const config = await readJsonFile(filePath);

    if (!config.RewardSystem) {
        throw new Error("RewardSystem address not found in config");
    }

    console.log("\n" + "=".repeat(80));
    console.log(`🌐 Network: ${net.name} (chainId: ${net.chainId})`);
    console.log(`📍 RewardSystem: ${config.RewardSystem}`);
    console.log("=".repeat(80) + "\n");

    const [signer] = await ethers.getSigners();
    console.log(`👤 Signer: ${await signer.getAddress()}\n`);

    // Connect to RewardSystem contract
    const rewardSystem = await ethers.getContractAt("RewardSystem", config.RewardSystem);

    console.log("REWARD SYSTEM", config.RewardSystem);

    // Owner check for contract interaction permission
    const owner: string = await rewardSystem.owner();
    if (owner.toLowerCase() !== (await signer.getAddress()).toLowerCase()) {
        throw new Error("❌ Not the owner of RewardSystem contract");
    }

    // Get token contract
    const tokenAddress: string = await rewardSystem.token();
    const token = await ethers.getContractAt("Token", tokenAddress);
    console.log(`🪙 Token: ${tokenAddress}\n`);

    const walletsData: WalletDistribution[] = [];

    // Load the wallet distribution data from JSON
    const data: { address: string, totalAmount: number }[] = JSON.parse(
        fs.readFileSync(path.join(__dirname, "../period_invest_stats.json"), "utf8")
    )["investors"];


    const TOTAL_TOKENS = Number(process.env.TOTAL_TOKENS);
    if(!TOTAL_TOKENS) {
        throw new Error("TOTAL_TOKENS is not set");
    }

    for(const item of data) {
        const wallet = item.address;
        const found = walletsData.find((w: WalletDistribution) => wallet === w.wallet);
        const investedUSDCAmount = Number(item.totalAmount) / 1e6;
        const rewardUSDAmount = investedUSDCAmount * 0.06; // 6% of the USDC amount

        if(found) {
            found.investedUSDCAmount += investedUSDCAmount; // Convert to USDC
            found.rewardUSDAmount += rewardUSDAmount;
        } else {
            walletsData.push({
                wallet,
                investedUSDCAmount,
                rewardUSDAmount,
            });
        }
    }

    const totalRewardUSDAmount = walletsData.reduce((sum, item) => sum + item.rewardUSDAmount, 0);

    const rewards: { wallet: string, rewardTokenAmount: number, rewardUSDAmount: number }[] = [];
    for(const item of walletsData) {
        rewards.push({
            wallet: item.wallet,
            rewardTokenAmount: item.rewardUSDAmount / totalRewardUSDAmount * TOTAL_TOKENS,
            rewardUSDAmount: item.rewardUSDAmount,
        });
    }

    rewards.sort((a: { wallet: string, rewardTokenAmount: number, rewardUSDAmount: number }, b: { wallet: string, rewardTokenAmount: number, rewardUSDAmount: number }) => a.rewardUSDAmount - b.rewardUSDAmount);

    console.log("rewards:", rewards);
    console.log("totalRewardUSDAmount:", totalRewardUSDAmount);

    console.log(`📊 Loaded ${walletsData.length} wallet distributions\n`);

    // Prepare data arrays for distribution
    const addresses: string[] = [];
    const amounts: bigint[] = [];


    for (const item of rewards) {
        addresses.push(item.wallet);
        amounts.push(ethers.parseEther(item.rewardTokenAmount.toString()));
        console.log(`${item.wallet}: ${item.rewardTokenAmount} tokens`);
    }

    let nonce: number = await ethers.provider.getTransactionCount(await signer.getAddress());

    console.log(`📦 Total wallets to distribute: ${addresses.length}`);
    const totalAmount: bigint = amounts.reduce((sum, val) => sum + val, 0n);
    console.log(`💰 Total amount: ${ethers.formatEther(totalAmount)} tokens\n`);

    // Check if RewardSystem has enough tokens
    const rewardSystemBalance: bigint = await token.balanceOf(config.RewardSystem);
    console.log(`💼 RewardSystem balance: ${ethers.formatEther(rewardSystemBalance)} tokens`);
    
    if (rewardSystemBalance < totalAmount) {
        throw new Error(
            `❌ Not enough tokens in RewardSystem!\n` +
            `   Required: ${ethers.formatEther(totalAmount)}\n` +
            `   Available: ${ethers.formatEther(rewardSystemBalance)}`
        );
    }
    console.log(`✅ Sufficient balance for distribution\n`);

    // Split into batches to avoid gas limits
    const batches: number = Math.ceil(addresses.length / BATCH_SIZE);
    console.log(`🔄 Processing in ${batches} batches (${BATCH_SIZE} addresses per batch)\n`);

    for (let i = 0; i < batches; i++) {
        const start: number = i * BATCH_SIZE;
        const end: number = Math.min((i + 1) * BATCH_SIZE, addresses.length);

        const batchAddresses: string[] = addresses.slice(start, end);
        const batchAmounts: bigint[] = amounts.slice(start, end);

        console.log(`📤 Batch ${i + 1}/${batches}: processing ${batchAddresses.length} addresses...`);
        console.log(`   Range: ${start} - ${end - 1}`);
        const batchAmount = batchAmounts.reduce((sum, val) => sum + val, 0n);
        console.log(`   Batch amount: ${ethers.formatEther(batchAmount)} tokens`);


        // Uncomment for test dry-run

        try {
            // Call the distribute function on RewardSystem contract
            const tx = await rewardSystem.distributeTokens(
                batchAddresses,
                batchAmounts,
                { nonce }
            );

            console.log(`   ⏳ Transaction sent: ${tx.hash}`);
            const receipt = await tx.wait();
            nonce++;
            console.log(`   ✅ Transaction confirmed in block ${receipt?.blockNumber}`);
            console.log(`   ⛽ Gas used: ${receipt?.gasUsed.toString()}\n`);
        } catch (error: any) {
            console.error(`   ❌ Error in batch ${i + 1}:`, error.message);
            throw error;
        }
    }

    console.log("=".repeat(80));
    console.log("✅ All tokens distributed successfully!");
    console.log("=".repeat(80) + "\n");
}

main().catch((error: unknown) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});