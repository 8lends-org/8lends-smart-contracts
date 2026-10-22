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
    const recorded: string | undefined = config[`${contractName}_impl`];

    /**
     * Writes the record from what the proxy actually points at.
     *
     * Everything in it described the implementation that has just been replaced, so it is
     * recomputed rather than carried over: a buildHash left from the old code together with
     * matchesDeployed=true would assert a verification that nothing has performed.
     *
     * The explorer goes first. It is the one public copy of the settings this was built with, and
     * it is cheapest to publish now, while the tree that produced the implementation is still the
     * tree in hand.
     */
    const adoptLiveImplementation = async (attributable: boolean): Promise<void> => {
      await verifyOnExplorer(hre, currentImpl);

      const { notes, ...described } = await describeDeployment(hre, contractName, proxyAddress, currentImpl);

      // HEAD is the right attribution only when this run is the one that performed the upgrade.
      // Adopting something found on chain is the other case: HEAD reproducing the bytecode says
      // the code is unchanged since, not that it was released from here, and a whole range of
      // commits reproduces it equally well. An attribution nothing established is worse than none.
      const record = attributable ? described : { ...described, deployedFrom: null };
      if (!attributable) {
        notes.push("deployedFrom left empty: which commit this went out as is not known from here");
      }
      saveDeployment(net.chainId, contractName, record);

      console.log("\n💾 deployments updated:");
      console.log(`   impl            ${currentImpl}`);
      console.log(`   buildHash       ${record.buildHash ?? "—"}`);
      console.log(`   matchesDeployed ${record.matchesDeployed}`);
      console.log(`   deployedFrom    ${record.deployedFrom ?? "—"}`);
      console.log(`   deployedAt      ${record.deployedAt ?? "—"}`);
      console.log(`   build           ${describeBuild(record.build)}`);
      for (const note of notes) console.log(`   · ${note}`);
    };

    if (config[pendingImplKey]) {
      console.log(`🔄 Expected implementation: ${config[pendingImplKey]}`);

      if (currentImpl.toLowerCase() === config[pendingImplKey].toLowerCase()) {
        console.log("\n✅ UPGRADE SUCCESSFUL! Implementation updated.");
        await adoptLiveImplementation(true);
      } else {
        console.log("\n⚠️  Implementation NOT updated. Upgrade not yet executed or an error occurred.");
      }
    } else if (recorded?.toLowerCase() !== currentImpl.toLowerCase()) {
      // No pending implementation, yet the proxy has moved: the upgrade did not go through the
      // route that writes one down. Recording it here is what lets the repository catch up — the
      // deployed-versions check reports the disagreement but may not author these fields, since
      // it has no way to tell a genuine upgrade from a working tree that happens to differ.
      console.log(`\n⚠️  The record says ${recorded ?? "nothing"}, the proxy points at ${currentImpl}.`);
      console.log("   An upgrade reached this proxy without being recorded. Adopting what is live.");
      await adoptLiveImplementation(false);
    } else {
      console.log(`📌 Implementation matches the record: ${recorded}`);
    }

    // Informational only: AccessControl contracts (BTC8L) have no owner().
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

    // Checked on the code, not through a view call: no view function exists on every contract here.
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

