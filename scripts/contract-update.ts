import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "./helpers";
dotenv.config();

// Get contract name from environment variable
const contractName = process.env.CONTRACT;

if (!contractName) {
  console.error(
    "Usage: CONTRACT=<ContractName> npx hardhat run scripts/contract-update.ts --network <network>"
  );
  console.error(
    "Example: CONTRACT=Fundraise npx hardhat run scripts/contract-update.ts --network base"
  );
  console.error(
    "Example: CONTRACT=LimitedSeller npx hardhat run scripts/contract-update.ts --network base"
  );
  console.error(
    "Example: CONTRACT=MaclearBonus npx hardhat run scripts/contract-update.ts --network base"
  );
  process.exit(1);
}

async function main() {
  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  console.log(`\nUpdating ${contractName} contract...`);

  const [signer] = await ethers.getSigners();
  const me = (await signer.getAddress()).toLowerCase();

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
    const factoryOwner = (await factory.owner()).toLowerCase();
    if (factoryOwner !== me) {
      console.log(`EscrowFactory: ${config.EscrowFactory}`);
      console.log(`Owner: ${factoryOwner}`);
      console.log(`Signer: ${me}`);
      throw new Error("Not the owner of EscrowFactory");
    }

    await hre.run("clean");
    await hre.run("compile");

    const AmlEscrowFactory = await hre.ethers.getContractFactory("AmlEscrow");
    const newImpl = await AmlEscrowFactory.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();

    await new Promise((resolve) => setTimeout(resolve, 2000));

    const tx = await factory.setImplementation(newImplAddress);
    await tx.wait();

    config.AmlEscrow = newImplAddress;
    await writeJsonFile(filePath, config);

    console.log(`✅ AmlEscrow implementation updated to ${newImplAddress}`);
    console.log("   ⚠️  Existing escrow clones still point to the OLD implementation (EIP-1167 immutability).");
    console.log("       Only escrows created AFTER this tx use the new implementation.");
    return;
  }

  const contractKey = contractName!;
  const implKey = `${contractName}_impl`;

  if (!config[contractKey]) {
    throw new Error(`${contractName} contract not found in config`);
  }

  // Check owner rights
  const contract = await ethers.getContractAt(contractName!, config[contractKey] as string);


    const owner = await contract.owner();
    if (owner.toLowerCase() !== me) {
      console.log(`Contract: ${config[contractKey]}`);
      console.log(`Owner: ${owner}`);
      console.log(`Signer: ${me}`);
      throw new Error("Not the owner");
    }


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
  await proxy.upgradeToAndCall(newImplAddress, initData);

  config[implKey] = newImplAddress;
  await writeJsonFile(filePath, config);

  console.log(`✅ ${contractName} updated! New impl: ${newImplAddress}`);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});