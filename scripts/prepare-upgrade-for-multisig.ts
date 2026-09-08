import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "./utils/helpers";
import { requireRealNetwork } from "./utils/network-guard";
dotenv.config();

/** One entry of a Transaction Builder batch, in the shape the app imports. */
interface SafeTransaction {
  to: string;
  value: string;
  /** null when contractMethod is used — the app encodes the calldata itself. */
  data: null;
  contractMethod: {
    name: string;
    payable: boolean;
    inputs: { name: string; type: string; internalType?: string }[];
  };
  /** Argument values keyed by input name; everything is a string here. */
  contractInputsValues: Record<string, string>;
}

/** Pulls a function's signature out of the compiled ABI so the batch matches the real contract. */
function contractMethodFromAbi(abi: any[], name: string): SafeTransaction["contractMethod"] {
  const entry = abi.find((e) => e.type === "function" && e.name === name);
  if (!entry) throw new Error(`${name} not found in ABI — is the contract UUPS?`);
  return {
    name: entry.name,
    payable: entry.stateMutability === "payable",
    inputs: entry.inputs.map((i: any) => ({
      name: i.name,
      type: i.type,
      internalType: i.internalType,
    })),
  };
}

async function main() {
  await requireRealNetwork();
  // The in-process `hardhat` network forks base and reports its chainId, so a run without
  // --network looks exactly like a real one. Rather than refuse, treat it as a rehearsal: the
  // implementation lands on a throwaway chain, so the batch is marked and the config is left alone.
  const isDryRun = hre.network.name === "hardhat";

  const contractName = process.env.CONTRACT;
  if (!contractName) {
    console.error("CONTRACT is not set.\n");
    console.error("  CONTRACT=<Name> npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network <network>");
    console.error("  e.g. CONTRACT=Fundraise npx hardhat run scripts/prepare-upgrade-for-multisig.ts --network base\n");
    console.error("<Name> is the config key of the proxy to upgrade.");
    process.exit(1);
  }

  const net = await ethers.provider.getNetwork();
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = await readJsonFile(filePath);

  const proxyAddress = config[contractName] as string | undefined;
  if (!proxyAddress) {
    throw new Error(`${contractName} not found in ${filePath}`);
  }

  const proxy = await ethers.getContractAt(contractName, proxyAddress);
  const owner = await proxy.owner();
  const currentImpl = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log(`\nNetwork:  ${net.name} (chainId ${net.chainId})`);
  console.log(`Contract: ${contractName} at ${proxyAddress}`);
  console.log(`Owner:    ${owner}`);
  console.log(`Old impl: ${currentImpl}`);
  if (isDryRun) {
    console.log("\nDRY RUN on the in-process fork: the implementation below will not exist on any");
    console.log("real chain. Pass --network base (or sepolia) to produce a submittable batch.");
  }

  console.log("\nCompiling from a clean state so the deployed bytecode matches the working tree...");
  await hre.run("clean");
  await hre.run("compile");

  const ContractFactory = await ethers.getContractFactory(contractName);
  const newImpl = await ContractFactory.deploy();
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();
  console.log(`New impl: ${newImplAddress}`);

  // Empty data: a plain upgrade with no reinitializer. If the new version needs one, encode the
  // reinitializer call here and the Safe UI will show it as the `data` argument.
  const upgradeData = "0x";

  const artifact = await hre.artifacts.readArtifact(contractName);
  const transaction: SafeTransaction = {
    to: proxyAddress,
    value: "0",
    data: null,
    contractMethod: contractMethodFromAbi(artifact.abi as any[], "upgradeToAndCall"),
    contractInputsValues: {
      newImplementation: newImplAddress,
      data: upgradeData,
    },
  };

  const batch = {
    version: "1.0",
    chainId: net.chainId.toString(),
    createdAt: Date.now(),
    meta: {
      name: isDryRun ? `DRY RUN — DO NOT SUBMIT — Upgrade ${contractName}` : `Upgrade ${contractName}`,
      description:
        (isDryRun
          ? "DRY RUN — DO NOT SUBMIT. Produced against the in-process fork; the implementation does " +
            "not exist on chain and this batch would revert. "
          : "") +
        `${contractName} ${proxyAddress}: upgradeToAndCall(${newImplAddress}, "${upgradeData}") — ` +
        `replaces implementation ${currentImpl}`,
      txBuilderVersion: "1.16.5",
      createdFromSafeAddress: owner,
      createdFromOwnerAddress: "",
    },
    transactions: [transaction],
  };

  // Distinct prefix so a rehearsal artifact cannot be mistaken for a submittable one, either in
  // the file listing or once dragged into Safe.
  const fileName = isDryRun
    ? `DRY-RUN-safe-upgrade-${contractName}-${net.chainId}.json`
    : `safe-upgrade-${contractName}-${net.chainId}.json`;
  const fs = await import("fs");
  fs.writeFileSync(fileName, JSON.stringify(batch, null, 2) + "\n");

  console.log(`\nBatch written to ${fileName}`);
  if (isDryRun) {
    console.log("Dry run: the config was left untouched, and this file must not be submitted.\n");
    return;
  }

  console.log("Safe → Apps → Transaction Builder → drag the file in → review → Create batch.");
  console.log("Signers should see upgradeToAndCall with newImplementation spelled out, not calldata.");

  // Recorded separately from `${contractName}_impl` because the upgrade has not happened yet —
  // it happens when the Safe executes the batch.
  const pendingKey = `${contractName}_impl_pending`;
  config[pendingKey] = newImplAddress;
  await writeJsonFile(filePath, config);
  console.log(`Config updated: ${pendingKey} = ${newImplAddress}\n`);
}

main().catch((error) => {
  console.error(`\nError: ${error.message}`);
  process.exit(1);
});
