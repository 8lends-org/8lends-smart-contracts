import dotenv from "dotenv";
import { ethers } from "hardhat";
import fs from "fs";
import path from "path";
import { readJsonFile } from "./helpers";

dotenv.config();

/**
 * Number of calls to include in a single Multicall batch for reading data.
 */
const BATCH_SIZE: number = 500;

/**
 * Maximum number of users allowed in a single batch transaction.
 */
const MAX_USERS_PER_TX: number = 100;

/**
 * Percentage of tokens to send, represented in basis points (e.g., 2.5% = 25000 basis points).
 */
const PERCENTAGE_TO_SEND: bigint = 25000n;
const BASIS_POINTS = 1000000n;

interface WalletDistribution {
    project_id: number;
    wallet: string;
    amount: number;
}

interface SendData {
    user: string;
    projectId: number;
    claimableAmount: bigint;
}

/**
 * Entrypoint for the batch sending tokens script.
 */
async function main() {
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

    // Connect to the RewardSystem contract
    const rewardSystem = await ethers.getContractAt("RewardSystem", config.RewardSystem);

    // Load Multicall3 ABI (used only for reading data)
    const multicall3Abi = JSON.parse(
        fs.readFileSync(path.join(__dirname, "../abis.others/Multicall3.json"), "utf8")
    );
    const multicall3 = new ethers.Contract(config.multicall3, multicall3Abi, signer);

    // Check if signer has manager permissions
    const managerRegistryAddress = await rewardSystem.managerRegistry();
    const managerRegistry = await ethers.getContractAt("ManagerRegistry", managerRegistryAddress);
    const isManager = await managerRegistry.isManager(await signer.getAddress());

    if (!isManager) {
        throw new Error("❌ Not a manager in ManagerRegistry contract");
    }

    // Load wallet and project distribution data
    const walletsData: WalletDistribution[] = JSON.parse(
        fs.readFileSync(path.join(__dirname, "../distribution/projects_wallets.json"), "utf8")
    );

    console.log(`📊 Loaded ${walletsData.length} wallet distributions\n`);

    // Deduplicate by user wallet + projectId to avoid double processing
    const uniqueWallets = new Map<string, WalletDistribution>();
    for (const item of walletsData) {
        const key = `${item.wallet.toLowerCase()}_${item.project_id}`;
        if (!uniqueWallets.has(key)) {
            uniqueWallets.set(key, item);
        }
    }

    console.log(`📊 Unique user-project combinations: ${uniqueWallets.size}\n`);

    // Prepare list of users and amounts for sending tokens
    const sendDataList: SendData[] = [];
    let totalToSend = 0n;
    let skippedCount = 0;

    console.log("🔍 Checking vesting information for each user-project...\n");

    // Convert the map to an array for batching reads
    const walletsArray = Array.from(uniqueWallets.values());
    const rewardSystemInterface = rewardSystem.interface;

    // Read vesting information in batches using Multicall3
    const readBatches = Math.ceil(walletsArray.length / BATCH_SIZE);
    console.log(`📚 Reading vesting info in ${readBatches} batches (${BATCH_SIZE} calls per batch)\n`);

    for (let batchIndex = 0; batchIndex < readBatches; batchIndex++) {
        const start = batchIndex * BATCH_SIZE;
        const end = Math.min((batchIndex + 1) * BATCH_SIZE, walletsArray.length);
        const batchWallets = walletsArray.slice(start, end);

        console.log(`📖 Reading batch ${batchIndex + 1}/${readBatches}: ${batchWallets.length} users...`);

        // Prepare calls for Multicall3
        const readCalls = batchWallets.map((item) => ({
            target: config.RewardSystem,
            allowFailure: true, // Allow individual call failures
            callData: rewardSystemInterface.encodeFunctionData("getVestingInfoForProject", [
                item.wallet,
                item.project_id
            ])
        }));

        try {
            // Execute Multicall3 for this batch
            const results = await multicall3.aggregate3.staticCall(readCalls);

            // Parse results
            for (let i = 0; i < results.length; i++) {
                const item = batchWallets[i];
                const result = results[i];

                if (!result.success) {
                    skippedCount++;
                    continue;
                }

                try {
                    // Decode the returned vesting information
                    const vestingInfo = rewardSystemInterface.decodeFunctionResult(
                        "getVestingInfoForProject",
                        result.returnData
                    );

                    const totalAmount = vestingInfo[0]; // totalRewardsTokens
                    const claimedAmount = vestingInfo[1]; // vestingClaimedAmount
                    const claimableAmount = vestingInfo[2]; // claimable now
                    const isActive = vestingInfo[4]; // isActive

                    // Skip if vesting schedule is not active
                    if (!isActive) {
                        skippedCount++;
                        continue;
                    }

                    // Skip if user was not allocated tokens for this project
                    if (totalAmount === 0n) {
                        skippedCount++;
                        continue;
                    }

                    // Calculate amount to send (2.5% of total)
                    const amountToSend = (totalAmount * PERCENTAGE_TO_SEND) / BASIS_POINTS;

                    // Skip if there is nothing left to send, or user has already claimed >= amountToSend
                    if (amountToSend === 0n || claimedAmount >= amountToSend) {
                        skippedCount++;
                        continue;
                    }

                    // Skip if available claimableAmount is less than what needs to be sent now
                    if (claimableAmount < amountToSend - claimedAmount) {
                        skippedCount++;
                        continue;
                    }

                    sendDataList.push({
                        user: item.wallet,
                        projectId: item.project_id,
                        claimableAmount: amountToSend - claimedAmount
                    });

                    totalToSend += amountToSend - claimedAmount;

                    console.log(
                        `✅ Ready to send: ${item.wallet} | Project ${item.project_id} | Amount: ${ethers.formatEther(amountToSend - claimedAmount)} tokens`
                    );
                } catch (error: any) {
                    console.error(`❌ Error decoding ${item.wallet} | Project ${item.project_id}:`, error.message);
                    skippedCount++;
                }
            }
        } catch (error: any) {
            console.error(`❌ Error reading batch ${batchIndex + 1}:`, error.message);
            // If reading batch fails, skip all users in batch
            skippedCount += batchWallets.length;
        }

        console.log(`   ✅ Batch ${batchIndex + 1} processed\n`);
    }

    console.log("\n" + "=".repeat(80));
    console.log(`📊 Summary:`);
    console.log(`   Users to send: ${sendDataList.length}`);
    console.log(`   Skipped: ${skippedCount}`);
    console.log(`   Total amount: ${ethers.formatEther(totalToSend)} tokens`);
    console.log("=".repeat(80) + "\n");

    if (sendDataList.length === 0) {
        console.log("⚠️  No users to send tokens. Exiting...");
        return;
    }

    // Split data into batches for native contract batch method
    const batches = Math.ceil(sendDataList.length / MAX_USERS_PER_TX);
    console.log(`🔄 Processing in ${batches} batches (max ${MAX_USERS_PER_TX} users per batch)\n`);

    let nonce = await ethers.provider.getTransactionCount(await signer.getAddress());

    for (let i = 0; i < batches; i++) {
        const start = i * MAX_USERS_PER_TX;
        const end = Math.min((i + 1) * MAX_USERS_PER_TX, sendDataList.length);
        const batchData = sendDataList.slice(start, end);

        console.log(`📤 Batch ${i + 1}/${batches}: processing ${batchData.length} users...`);
        console.log(`   Range: ${start} - ${end - 1}`);

        const batchAmount = batchData.reduce((sum, item) => sum + item.claimableAmount, 0n);
        console.log(`   Batch amount: ${ethers.formatEther(batchAmount)} tokens`);

        // Prepare user and project arrays for batch send
        const users = batchData.map(item => item.user);
        const projectIds = batchData.map(item => item.projectId);

        try {
            // Call the batch sendTokensForProjectToUserBatch method on RewardSystem
            const tx = await rewardSystem.sendTokensForProjectToUserBatch(users, projectIds, { nonce });

            console.log(`   ⏳ Transaction sent: ${tx.hash}`);
            const receipt = await tx.wait();
            nonce++;
            console.log(`   ✅ Transaction confirmed in block ${receipt?.blockNumber}`);
            console.log(`   ⛽ Gas used: ${receipt?.gasUsed.toString()}`);
            console.log(`   💰 Sent ${batchData.length} transfers\n`);
        } catch (error: any) {
            console.error(`   ❌ Error in batch ${i + 1}:`, error.message);

            // Decode on-chain revert errors if available
            if (error.data) {
                try {
                    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(['string'], '0x' + error.data.slice(10));
                    console.error(`   Decoded error: ${decoded[0]}`);
                } catch {
                    console.error(`   Error data: ${error.data}`);
                }
            }

            console.error(`\n   ⚠️  Failed users in this batch:`);
            for (let j = 0; j < batchData.length; j++) {
                const item = batchData[j];
                console.error(`      ${j}: ${item.user} | Project ${item.projectId} | Amount: ${ethers.formatEther(item.claimableAmount)}`);
            }

            throw error;
        }
    }

    console.log("=".repeat(80));
    console.log("✅ All tokens sent successfully!");
    console.log("=".repeat(80) + "\n");
}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});
