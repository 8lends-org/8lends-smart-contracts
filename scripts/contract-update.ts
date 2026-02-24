import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
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
  process.exit(1);
}

async function main() {
  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  console.log(`\nUpdating ${contractName} contract...`);

  const [signer] = await ethers.getSigners();
  const contractKey = contractName!;
  const implKey = `${contractName}_impl`;

  if (!config[contractKey]) {
    throw new Error(`${contractName} contract not found in config`);
  }

  // Check owner rights
  const contract = await ethers.getContractAt(contractName!, config[contractKey] as string);
  const owner = await contract.owner();
  if (owner.toLowerCase() !== (await signer.getAddress()).toLowerCase()) {
    console.log(`Contract: ${config[contractKey]}`);
    console.log(`Owner: ${owner}`);
    console.log(`Signer: ${await signer.getAddress()}`);
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
