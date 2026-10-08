import dotenv from "dotenv";
import hre, { ethers, upgrades } from "hardhat";
import { loadConfig, saveDeployment, type Deployment } from "./utils/config";
import { describeDeployment, verifyOnExplorer } from "./utils/provenance";
import { tryReadOwner } from "./utils/safe-batch";

import { requireRealNetwork } from "./utils/network-guard";
dotenv.config();

/**
 * Build settings for the console. `yul` prints as unknown rather than as off when the settings
 * carry no `optimizer.details`: a flattened verification does not publish them, and that is not
 * the same claim as the yul optimizer having been disabled.
 */
function describeBuild(build: Deployment["build"]): string {
  if (!build) return "—";
  const { solc, optimizer, evmVersion } = build;
  const yul = optimizer.details ? String(optimizer.details.yul) : "unknown";
  return `${solc}, runs=${optimizer.runs ?? "unknown"}, yul=${yul}, ${evmVersion ?? "unknown"}`;
}

/**
 * Verify contract upgrade success
 *
 * Usage: CONTRACT=Fundraise npx hardhat run scripts/verify-upgrade.ts --network base
 */

async function main() {
  await requireRealNetwork();
  const contractName = process.env.CONTRACT;

  if (!contractName) {
    console.error("\n❌ CONTRACT not specified");
    console.error("Usage: CONTRACT=<ContractName> npx hardhat run scripts/verify-upgrade.ts --network <network>");
    process.exit(1);
  }

  const net = await ethers.provider.getNetwork();
  console.log("\n" + "=".repeat(80));
  console.log(`🌐 Network: ${net.name} (chainId: ${net.chainId})`);
  console.log("=".repeat(80));

  const config = loadConfig(net.chainId);

  const proxyAddress = config[contractName];

  if (!proxyAddress) {
    throw new Error(`❌ ${contractName} not found in config`);
  }

  console.log(`\n📋 Contract: ${contractName}`);
  console.log(`📍 Proxy address: ${proxyAddress}`);

  try {
    // Get current implementation
    const currentImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`📦 Current implementation: ${currentImpl}`);

    // Check pending implementation from config
    const pendingImplKey = `${contractName}_impl_pending`;
    const oldImplKey = `${contractName}_impl`;
    
    if (config[pendingImplKey]) {
      console.log(`🔄 Expected implementation: ${config[pendingImplKey]}`);
      
      if (currentImpl.toLowerCase() === config[pendingImplKey].toLowerCase()) {
        console.log("\n✅ UPGRADE SUCCESSFUL! Implementation updated.");
        
        // Verify on the explorer before recording anything. It is the one public copy of the
        // settings this was built with, and it is cheapest to publish now, while the tree that
        // produced the implementation is still the tree in hand.
        await verifyOnExplorer(hre, currentImpl);

        // Everything else in the record described the implementation that has just been replaced,
        // so it is recomputed rather than carried over: a buildHash left from the old code together
        // with matchesDeployed=true would assert a verification that nothing has performed.
        const { notes, ...record } = await describeDeployment(hre, contractName, proxyAddress, currentImpl);
        saveDeployment(net.chainId, contractName, record);

        console.log("\n💾 deployments updated:");
        console.log(`   buildHash       ${record.buildHash ?? "—"}`);
        console.log(`   matchesDeployed ${record.matchesDeployed}`);
        console.log(`   deployedFrom    ${record.deployedFrom ?? "—"}`);
        console.log(`   deployedAt      ${record.deployedAt ?? "—"}`);
        console.log(`   build           ${describeBuild(record.build)}`);
        for (const note of notes) console.log(`   · ${note}`);
      } else {
        console.log("\n⚠️  Implementation NOT updated. Upgrade not yet executed or an error occurred.");
      }
    } else {
      console.log(`📌 Implementation from config: ${config[oldImplKey] || 'not found'}`);
    }

    // Owner is informational: contracts on AccessControl (BTC8L) have no owner() at all.
    const contract = await ethers.getContractAt(contractName, proxyAddress);
    const owner = await tryReadOwner(contractName, proxyAddress);
    console.log(`👤 Owner: ${owner ?? "none (no owner(), access is role-based)"}`);

    // Try to get version if available
    try {
      const version = await contract.version();
      console.log(`📌 Version: ${version}`);
    } catch (e) {
      // Version not implemented - this is normal
    }

    // The proxy has to delegate to actual code. Checked on the implementation rather than through a
    // view call, because no single view function exists on every contract this script handles.
    console.log("\n🔍 Checking basic functionality...");
    if ((await ethers.provider.getCode(currentImpl)) === "0x") {
      throw new Error(`Implementation ${currentImpl} has no code`);
    }
    console.log("✅ Implementation has code");

    console.log("\n" + "=".repeat(80));
    console.log("✅ Verification completed successfully");
    console.log("=".repeat(80) + "\n");

  } catch (error: any) {
    console.error(`\n❌ Error during verification: ${error.message}\n`);
    process.exit(1);
  }
}

main().catch(error => {
  console.error("❌ Critical error:", error);
  process.exit(1);
});

