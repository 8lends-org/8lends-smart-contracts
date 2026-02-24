import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";
import { formatUnits, parseUnits } from "ethers";

dotenv.config();

// Swap parameters (can be changed)
// The exact amount of tokens to buy is obtained from the environment variable
const AMOUNT_TO_MINT = process.env.AMOUNT_TO_MINT;
const CONTRACT : "RewardSystem" | "Rewards2" = process.env.CONTRACT as "RewardSystem" | "Rewards2";

/**
 * Script for minting rewards for a project.
 */
async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    console.log("network: ", net.name);

    const config: {
        uniswapV2Router: string;
        usdc: string;
        token: string;
        RewardSystem: string;
        Rewards2: string;
    } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

    if(!AMOUNT_TO_MINT) {
        throw new Error("❌ AMOUNT_TO_MINT is not set");
    }
    if(!CONTRACT) {
        throw new Error("❌ CONTRACT is not set");
    }

    if(!config[CONTRACT]) {
        throw new Error(`❌ ${CONTRACT} is not set`);
    }

    const [signer] = await ethers.getSigners();

    const amount = parseUnits(AMOUNT_TO_MINT, 18);


    const CONTRACT_ABI = readFileSync(join(__dirname, `../abis/${CONTRACT}.json`), "utf8");
    const contract = new ethers.Contract(config[CONTRACT], CONTRACT_ABI, signer);
    const mintTx = await contract.mintRewardsTWAP(amount);
    console.log(`   ⏳ Mint transaction sent: ${mintTx.hash}`);
    await mintTx.wait();
    console.log(`   ✅ Mint confirmed in block`);

}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});
