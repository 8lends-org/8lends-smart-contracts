import dotenv from "dotenv";
import { ethers } from "hardhat";
import fs from "fs";
import path from "path";
import { readJsonFile } from "./helpers";


interface WalletDistribution {
    wallet: string;
    amount: number;
}

dotenv.config();

/**
 * Number of addresses in one batch to avoid gas limit issues
 */
const BATCH_SIZE = 500;
const FILE_PATH = process.env.FILE_PATH;
if(!FILE_PATH) {
    throw new Error("❌ FILE_PATH is not set");
}

    // Load the wallet distribution data from JSON
    const walletsData: WalletDistribution[] = JSON.parse(
        fs.readFileSync(path.join(__dirname, `../${FILE_PATH}`), "utf8")
    );

    console.log(`📊 Loaded ${walletsData.length} wallet distributions\n`);


/**
 * Main function to distribute vesting tokens to wallet distributions.
 */
async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    const filePath = `./scripts/config/${net.chainId}-config.json`;
    const config = await readJsonFile(filePath);

    if (!config.Rewards2) {
        throw new Error("Rewards2 address not found in config");
    }

    console.log("\n" + "=".repeat(80));
    console.log(`🌐 Network: ${net.name} (chainId: ${net.chainId})`);
    console.log(`📍 Rewards2: ${config.Rewards2}`);
    console.log("=".repeat(80) + "\n");

    const [signer] = await ethers.getSigners();
    console.log(`👤 Signer: ${await signer.getAddress()}\n`);

    const rewards2 = await ethers.getContractAt("Rewards2", config.Rewards2);

    console.log("REWARDS2", config.Rewards2);

    // Owner check for contract interaction permission
    const owner: string = await rewards2.owner();
    if (owner.toLowerCase() !== (await signer.getAddress()).toLowerCase()) {
        throw new Error("❌ Not the owner of Rewards2 contract");
    }



    // Prepare data arrays for distribution
    const addresses: string[] = [];
    const amounts: bigint[] = [];

    for (const item of walletsData) {
        addresses.push(item.wallet);
        // Convert amount to wei (tokens with 18 decimals)
        amounts.push(ethers.parseEther(item.amount.toString()));
    }

    if(addresses.length === 0) {
        throw new Error("❌ No addresses found in the file");
    }
    if(amounts.length!== addresses.length) {
        throw new Error("❌ Amounts and addresses length mismatch");
    }

    let nonce: number = await ethers.provider.getTransactionCount(await signer.getAddress());

    console.log(`📦 Total wallets to distribute: ${addresses.length}`);
    const totalAmount: bigint = amounts.reduce((sum, val) => sum + val, 0n);
    console.log(`💰 Total amount: ${ethers.formatEther(totalAmount)} tokens\n`);

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
        // return;

        try {
            const tx = await rewards2.createVesting(
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