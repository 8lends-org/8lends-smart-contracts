import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "./helpers";
dotenv.config();

/**
 * Prepare data for contract upgrade via Gnosis Safe
 * 
 * Script:
 * 1. Deploys new implementation
 * 2. Generates calldata for upgradeToAndCall
 * 3. Outputs data for Transaction Builder in Safe
 * 
 * Usage: CONTRACT=Fundraise npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network base
 */

async function main() {
  const contractName = process.env.CONTRACT;

  if (!contractName) {
    console.error("\n❌ CONTRACT not specified");
    console.error("Usage: CONTRACT=<ContractName> npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network <network>");
    console.error("\nExamples:");
    console.error("  CONTRACT=Fundraise npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network base");
    console.error("  CONTRACT=Treasury npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network base_sepolia");
    process.exit(1);
  }

  const net = await ethers.provider.getNetwork();
  console.log("\n" + "=".repeat(80));
  console.log(`🌐 Network: ${net.name} (chainId: ${net.chainId})`);
  console.log("=".repeat(80));

  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  const contractKey = contractName;
  const proxyAddress = config[contractKey];

  if (!proxyAddress) {
    throw new Error(`❌ ${contractName} not found in config: ${filePath}`);
  }

  console.log(`\n📋 Contract: ${contractName}`);
  console.log(`📍 Proxy address: ${proxyAddress}`);

  // Check current owner
  const contract = await ethers.getContractAt(contractName, proxyAddress);
  const currentOwner = await contract.owner();
  console.log(`👤 Current owner: ${currentOwner}`);

  // Get current implementation
  const currentImpl = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log(`📦 Current implementation: ${currentImpl}`);

  // Compile contracts
  console.log("\n🔨 Compiling contracts...");
  await hre.run("clean");
  await hre.run("compile");
  console.log("✅ Compilation completed");

  // Deploy new implementation
  console.log("\n🚀 Deploying new implementation...");
  const ContractFactory = await ethers.getContractFactory(contractName);
  const newImpl = await ContractFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();

  console.log(`✅ New implementation deployed: ${newImplAddress}`);

  // Prepare upgrade data
  const upgradeData = "0x"; // Empty data for regular upgrade without reinitialization
  
  // Encode upgradeToAndCall call
  const upgradeCalldata = contract.interface.encodeFunctionData("upgradeToAndCall", [
    newImplAddress,
    upgradeData
  ]);

  console.log("\n" + "=".repeat(80));
  console.log("📤 DATA FOR TRANSACTION BUILDER IN GNOSIS SAFE");
  console.log("=".repeat(80));
  console.log("\n1️⃣ Open: https://app.safe.global/");
  console.log("2️⃣ Select your Safe");
  console.log("3️⃣ Go to Apps -> Transaction Builder");
  console.log("4️⃣ Enter the following data:\n");
  
  console.log("┌─────────────────────────────────────────────────────────────────┐");
  console.log("│ To (Contract Address):                                           │");
  console.log(`│ ${proxyAddress}                                          │`);
  console.log("├─────────────────────────────────────────────────────────────────┤");
  console.log("│ Value (ETH):                                                    │");
  console.log("│ 0                                                               │");
  console.log("├─────────────────────────────────────────────────────────────────┤");
  console.log("│ ABI (select Custom):                                             │");
  console.log("│ Insert upgradeToAndCall method or use Data below                │");
  console.log("├─────────────────────────────────────────────────────────────────┤");
  console.log("│ Data (Calldata):                                                │");
  console.log(`│ ${upgradeCalldata}`);
  console.log("└─────────────────────────────────────────────────────────────────┘");

  console.log("\n" + "=".repeat(80));
  console.log("📋 UPGRADE DETAILS");
  console.log("=".repeat(80));
  console.log(`Contract:           ${contractName}`);
  console.log(`Proxy:              ${proxyAddress}`);
  console.log(`Old impl:           ${currentImpl}`);
  console.log(`New impl:           ${newImplAddress}`);
  console.log(`Owner (Safe):       ${currentOwner}`);
  console.log("=".repeat(80));

  // Save data to file for convenience
  const upgradeDataFile = {
    network: net.name,
    chainId: net.chainId.toString(),
    contractName,
    proxyAddress,
    currentImplementation: currentImpl,
    newImplementation: newImplAddress,
    owner: currentOwner,
    calldata: upgradeCalldata,
    value: "0",
    timestamp: new Date().toISOString(),
    safeUrl: "https://app.safe.global/",
    instructions: {
      step1: "Open Safe at https://app.safe.global/",
      step2: "Go to Apps -> Transaction Builder",
      step3: "Enter transaction data",
      step4: "Add transaction and review",
      step5: "Create batch and collect signatures",
      step6: "Execute when threshold is reached"
    }
  };

  const fileName = `upgrade-${contractName}-${Date.now()}.json`;
  const fs = await import("fs");
  fs.writeFileSync(fileName, JSON.stringify(upgradeDataFile, null, 2));
  
  console.log(`\n💾 Data saved to file: ${fileName}`);
  console.log("\n✅ Preparation completed!");
  console.log("\n📝 Next steps:");
  console.log("   1. Copy the data above to Transaction Builder");
  console.log("   2. Review transaction details");
  console.log("   3. Create transaction (Create batch)");
  console.log("   4. Collect signatures from signers");
  console.log("   5. Execute transaction (Execute)\n");

  // Update config with new implementation (for history)
  const implKey = `${contractName}_impl_pending`;
  config[implKey] = newImplAddress;
  await writeJsonFile(filePath, config);
  console.log(`💡 New impl saved to config as '${implKey}'\n`);
}

main().catch(error => {
  console.error("\n❌ Error:", error.message);
  process.exit(1);
});

