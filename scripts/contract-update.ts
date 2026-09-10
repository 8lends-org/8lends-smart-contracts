import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { loadConfig, saveDeployment } from "./utils/config";

import { describeDeployment, printDeploymentRecord, verifyOnExplorer } from "./utils/provenance";
import { requireOwner } from "./utils/owner-guard";
import { requireRealNetwork } from "./utils/network-guard";
dotenv.config();

// Get contract name from environment variable
const contractName = process.env.CONTRACT;

if (!contractName) {
  console.error("CONTRACT is not set.\n");
  console.error("  CONTRACT=<Name> npx hardhat run scripts/contract-update.ts --network <network>");
  console.error("  e.g. CONTRACT=Fundraise npx hardhat run scripts/contract-update.ts --network base\n");
  console.error("<Name> is the config key of the proxy to upgrade. The signer must be its owner —");
  console.error("if the owner is a Safe, use scripts/prepare-upgrade-for-multisig.ts instead.");
  process.exit(1);
}

/**
 * Writes the whole deployment record, not just the address.
 *
 * This path has no pending state — the implementation is deployed and pointed at in the same run,
 * so unlike the Safe path there is nothing to clear. What there is to do is fill every field: a new
 * implementation invalidates buildHash, build, deployedFrom and deployedAt at once, and saveConfig
 * deliberately cannot touch them.
 */
async function record(name: string, proxy: string, impl: string | null, block?: number): Promise<void> {
  const net = await ethers.provider.getNetwork();
  const { notes, ...rec } = await describeDeployment(hre, name, proxy, impl, { deployedAtBlock: block });
  saveDeployment(net.chainId, name, rec);
  printDeploymentRecord(rec, notes);
}

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  const config = loadConfig(net.chainId);

  console.log(`\nUpdating ${contractName} contract...`);

  // Special case: AmlEscrow is NOT a proxy. It's the implementation for EIP-1167
  // clones created by EscrowFactory. "Updating" means deploying a new impl and
  // pointing EscrowFactory.implementation() to it via setImplementation().
  // IMPORTANT: existing per-user clones remain pinned to the OLD impl forever
  // (EIP-1167 hardcodes the impl address into bytecode). Only NEW escrows use
  // the new impl.
  if (contractName === "AmlEscrow") {
    if (!config.EscrowFactory) {
      throw new Error("EscrowFactory not found in config — deploy EscrowFactory first");
    }

    const factory = await ethers.getContractAt("EscrowFactory", config.EscrowFactory as string);
    await requireOwner(config.EscrowFactory as string, "EscrowFactory");

    await hre.run("clean");
    await hre.run("compile");

    const AmlEscrowFactory = await hre.ethers.getContractFactory("AmlEscrow");
    const newImpl = await AmlEscrowFactory.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();

    await new Promise((resolve) => setTimeout(resolve, 2000));

    const tx = await factory.setImplementation(newImplAddress);
    const receipt = await tx.wait();

    // AmlEscrow is not behind a proxy, so the record's address IS the implementation and `impl`
    // stays null. The block is passed in because there is no ERC-1967 slot to bisect for it.
    await verifyOnExplorer(hre, newImplAddress);
    await record("AmlEscrow", newImplAddress, null, receipt?.blockNumber);

    console.log(`✅ AmlEscrow implementation updated to ${newImplAddress}`);
    console.log("   ⚠️  Existing escrow clones still point to the OLD implementation (EIP-1167 immutability).");
    console.log("       Only escrows created AFTER this tx use the new implementation.");
    return;
  }

  const contractKey = contractName!;

  if (!config[contractKey]) {
    throw new Error(`${contractName} contract not found in config`);
  }

  await requireOwner(config[contractKey] as string, contractName!);

  // Force update
  await hre.run("clean");
  await hre.run("compile");

  const ContractFactory = await hre.ethers.getContractFactory(contractName!);

  // When updating UUPS contract, initialize does not need to be called
  // Contract is already initialized on first deployment
  let initData = "0x";

  const newImpl = await ContractFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();

  // Wait so the RPC has updated nonce and does not reject the next tx as "already known"
  await new Promise(resolve => setTimeout(resolve, 2000));

  const proxy = await ethers.getContractAt(contractName!, config[contractKey] as string);
  // Waited for on purpose: the record below is written from chain state, and the block number of
  // this receipt is what deployedAt is taken from.
  const upgradeTx = await proxy.upgradeToAndCall(newImplAddress, initData);
  const upgradeReceipt = await upgradeTx.wait();

  await verifyOnExplorer(hre, newImplAddress);
  await record(contractName!, config[contractKey] as string, newImplAddress, upgradeReceipt?.blockNumber);

  console.log(`✅ ${contractName} updated! New impl: ${newImplAddress}`);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});