import dotenv from "dotenv";
import type { Contract } from "ethers";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "./helpers";

dotenv.config();

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
    "Example: CONTRACT=BTC8L npx hardhat run scripts/contract-update.ts --network base_sepolia"
  );
  process.exit(1);
}

/**
 * UUPS via Ownable: owner(). BTC8L: UPGRADER_ROLE (or DEFAULT_ADMIN if same holder).
 */
async function signerMayUpgrade(proxy: Contract, signerAddress: string): Promise<boolean> {
  try {
    const upgraderRole = await proxy.getFunction("UPGRADER_ROLE")();
    if (await proxy.hasRole(upgraderRole, signerAddress)) {
      return true;
    }
  } catch {
    /* no UPGRADER_ROLE */
  }
  try {
    const adminRole = await proxy.getFunction("DEFAULT_ADMIN_ROLE")();
    if (await proxy.hasRole(adminRole, signerAddress)) {
      return true;
    }
  } catch {
    /* no AccessControl */
  }
  try {
    const ownerFn = proxy.getFunction("owner");
    const ownerAddr = (await ownerFn()) as string;
    return ownerAddr.toLowerCase() === signerAddress.toLowerCase();
  } catch {
    return false;
  }
}

async function main(): Promise<void> {
  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = (await readJsonFile(filePath)) as Record<string, string>;

  console.log(`\nUpdating ${contractName} contract...`);

  const [signer] = await ethers.getSigners();
  const signerAddress = await signer.getAddress();
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
  

  await hre.run("clean");
  await hre.run("compile");

  const ContractFactory = await hre.ethers.getContractFactory(contractName!);
  const initData = "0x";

  const gasPrice = await ethers.provider.getFeeData();
  console.log("Gas price:", Number(gasPrice.gasPrice) / 1e9);
  const balance = await ethers.provider.getBalance(signerAddress);
  console.log("Balance:", ethers.formatEther(balance));
  const newImpl = await ContractFactory.deploy();
  console.log("New implementation deployed to:", newImpl.target);
  console.log("waiting for deployment...");
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();
  console.log("New implementation address:", newImplAddress);

  

  const proxy = await ethers.getContractAt(contractName!, proxyAddress);
  await proxy.upgradeToAndCall(newImplAddress, initData);
  config[implKey] = newImplAddress;
  await writeJsonFile(filePath, config);
  console.log(`✅ ${contractName} updated! New impl: ${newImplAddress}`);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
