import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";

dotenv.config();

// Swap parameters (can be changed)
// The exact amount of tokens to buy is obtained from the environment variable
const CONTRACT : "RewardSystem" | "Rewards2" | "Lending8" = process.env.CONTRACT as "RewardSystem" | "Rewards2" | "Lending8";

/**
 * Script for setting the oracle in the contract.
 */
async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    console.log("network: ", net.name);

    const config: {
        RewardSystem: string;
        Rewards2: string;
        Oracle: string;
        Lending8: string;
    } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

    if(!CONTRACT) {
        throw new Error("❌ CONTRACT is not set");
    }

    if(!config[CONTRACT]) {
        throw new Error(`❌ ${CONTRACT} is not set`);
    }

    const [signer] = await ethers.getSigners();



    const CONTRACT_ABI = readFileSync(join(__dirname, `../abis/${CONTRACT}.json`), "utf8");
    const contract = new ethers.Contract(config[CONTRACT], CONTRACT_ABI, signer);
    const updateOracleTx = await contract.setOracle(config.Oracle);
    console.log(`   ⏳ Update Oracle transaction sent: ${updateOracleTx.hash}`);
    await updateOracleTx.wait();
    console.log(`   ✅ Update Oracle confirmed in block`);

}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
<<<<<<< HEAD
});
=======
});
>>>>>>> c3cf245968ed6120c7e1a990127bc6a59e9d3c7c
