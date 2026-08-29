import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";
import { requireOwner } from "./utils/owner-guard";
import { requireRealNetwork } from "./utils/network-guard";

dotenv.config();

// Target contract for setOracle(address) is selected via CONTRACT env var.
type OracleTarget = "RewardSystem" | "Rewards2" | "Lending8" | "Fundraise";
const CONTRACT: OracleTarget = process.env.CONTRACT as OracleTarget;

/**
 * Script for setting the oracle in the contract.
 */
async function main(): Promise<void> {
  await requireRealNetwork();
    const net = await ethers.provider.getNetwork();
    console.log("network: ", net.name);

    const config: {
        RewardSystem: string;
        Rewards2: string;
        Oracle: string;
        Lending8: string;
        Fundraise: string;
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
    await requireOwner(config[CONTRACT], CONTRACT);
    const updateOracleTx = await contract.setOracle(config.Oracle);
    console.log(`   ⏳ Update Oracle transaction sent: ${updateOracleTx.hash}`);
    await updateOracleTx.wait();
    console.log(`   ✅ Update Oracle confirmed in block`);

}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});