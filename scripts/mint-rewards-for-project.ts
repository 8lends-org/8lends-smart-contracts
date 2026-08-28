import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";
import { formatUnits } from "ethers";
import { requireOwner } from "./utils/owner-guard";
import { requireRealNetwork } from "./utils/network-guard";

dotenv.config();

// Swap parameters (can be changed)
// The exact amount of tokens to buy is obtained from the environment variable
const BLOCKCHAIN_PROJECT_ID = process.env.BLOCKCHAIN_PROJECT_ID;

/**
 * Script for minting rewards for a project.
 */
async function main(): Promise<void> {
  requireRealNetwork();
    const net = await ethers.provider.getNetwork();
    console.log("network: ", net.name);

    const config: {
        uniswapV2Router: string;
        usdc: string;
        token: string;
        RewardSystem: string;
    } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

    if(!BLOCKCHAIN_PROJECT_ID) {
        throw new Error("❌ BLOCKCHAIN_PROJECT_ID is not set");
    }
    if(!config?.RewardSystem) {
        throw new Error("❌ RewardSystem is not set");
    }

    const [signer] = await ethers.getSigners();


        const RewardSystemABI = readFileSync(join(__dirname, `../abis/RewardSystem.json`), "utf8");
        const rewardSystem = new ethers.Contract(config.RewardSystem, RewardSystemABI, signer);
        await requireOwner(config.RewardSystem, "RewardSystem");
        const mintTx = await rewardSystem.mintRewardsForProject(BLOCKCHAIN_PROJECT_ID);
        console.log(`   ⏳ Mint transaction sent: ${mintTx.hash}`);
        await mintTx.wait();
        console.log(`   ✅ Mint confirmed in block`);

    
}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});
