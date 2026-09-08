import hre from "hardhat";
import { writeFileSync } from "fs";

/**
 * Builds Safe Transaction Builder batches — the JSON you drag into Safe → Apps → Transaction
 * Builder. Transactions carry the decoded method and arguments instead of raw calldata, so signers
 * read `setAmlGateway(0x1419…)` rather than a hex blob they cannot check.
 */

/** One entry of a batch, in the shape the app imports. */
export interface SafeTransaction {
  to: string;
  value: string;
  /** null when contractMethod is used — the app encodes the calldata itself. */
  data: null;
  contractMethod: {
    name: string;
    payable: boolean;
    inputs: { name: string; type: string; internalType?: string }[];
  };
  /** Argument values keyed by input name; the app expects strings. */
  contractInputsValues: Record<string, string>;
}

type AbiFunction = {
  type: string;
  name: string;
  stateMutability: string;
  inputs: { name: string; type: string; internalType?: string }[];
};

/** Canonical `name(type,type)` signature of an ABI function entry. */
export function signatureOf(entry: AbiFunction): string {
  return `${entry.name}(${entry.inputs.map((i) => i.type).join(",")})`;
}

/**
 * Finds a function in the ABI by name, or by full `name(type,...)` signature when the name is
 * overloaded. Reading the signature out of the compiled ABI keeps the batch in step with the real
 * contract instead of a hand-written copy.
 */
export function findAbiFunction(abi: unknown[], method: string): AbiFunction {
  const functions = (abi as AbiFunction[]).filter((e) => e.type === "function");

  // A Safe transaction never calls a view, so only state-changing functions are worth suggesting.
  const callable = () =>
    [...new Set(
      functions
        .filter((e) => e.stateMutability !== "view" && e.stateMutability !== "pure")
        .map(signatureOf)
    )].sort().join(", ");

  if (method.includes("(")) {
    const bySignature = functions.find((e) => signatureOf(e) === method);
    if (!bySignature) {
      throw new Error(`No function ${method}. State-changing functions: ${callable()}`);
    }
    return bySignature;
  }

  const matches = functions.filter((e) => e.name === method);
  if (matches.length === 0) {
    throw new Error(`No function named ${method}. State-changing functions: ${callable()}`);
  }
  if (matches.length > 1) {
    throw new Error(
      `${method} is overloaded — pass the full signature, one of: ${matches.map(signatureOf).join(", ")}`
    );
  }
  return matches[0];
}

export function contractMethodOf(entry: AbiFunction): SafeTransaction["contractMethod"] {
  return {
    name: entry.name,
    payable: entry.stateMutability === "payable",
    inputs: entry.inputs.map((i) => ({ name: i.name, type: i.type, internalType: i.internalType })),
  };
}

/** Safe expects every argument as a string, including bools and numbers. */
function toInputValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "boolean" || typeof value === "number" || typeof value === "bigint") {
    return String(value);
  }
  return JSON.stringify(value);
}

export function buildTransaction(to: string, entry: AbiFunction, args: unknown[]): SafeTransaction {
  if (args.length !== entry.inputs.length) {
    throw new Error(`${signatureOf(entry)} takes ${entry.inputs.length} argument(s), got ${args.length}`);
  }
  const contractInputsValues: Record<string, string> = {};
  entry.inputs.forEach((input, i) => {
    // Unnamed ABI inputs still need a key; Safe falls back to the position.
    contractInputsValues[input.name || `arg${i}`] = toInputValue(args[i]);
  });
  return {
    to,
    value: "0",
    data: null,
    contractMethod: contractMethodOf(entry),
    contractInputsValues,
  };
}

/**
 * True when running against the in-process network. It forks base and reports its chainId, so a run
 * without --network is indistinguishable from a real one by its output alone — hence the marking in
 * writeBatch, and why callers must not write to the config in this case.
 */
export function isDryRun(): boolean {
  return hre.network.name === "hardhat";
}

const DRY_RUN_WARNING =
  "DRY RUN — DO NOT SUBMIT. Produced against the in-process fork; addresses deployed by this run " +
  "do not exist on chain. ";

/**
 * Writes the batch and returns the file name. On a dry run the name is prefixed and the warning is
 * carried inside `meta`, so a rehearsal artifact stays recognisable both in the file listing and
 * after being dragged into Safe.
 */
export function writeBatch(params: {
  chainId: bigint | string;
  name: string;
  description: string;
  safeAddress: string;
  transactions: SafeTransaction[];
  fileStem: string;
}): string {
  const dry = isDryRun();
  const batch = {
    version: "1.0",
    chainId: params.chainId.toString(),
    createdAt: Date.now(),
    meta: {
      name: dry ? `DRY RUN — DO NOT SUBMIT — ${params.name}` : params.name,
      description: (dry ? DRY_RUN_WARNING : "") + params.description,
      txBuilderVersion: "1.16.5",
      createdFromSafeAddress: params.safeAddress,
      createdFromOwnerAddress: "",
    },
    transactions: params.transactions,
  };

  const fileName = `${dry ? "DRY-RUN-" : ""}${params.fileStem}.json`;
  writeFileSync(fileName, JSON.stringify(batch, null, 2) + "\n");
  return fileName;
}

/** Owner of the target, or undefined when it has no owner() or the call is unavailable. */
export async function tryReadOwner(contractName: string, address: string): Promise<string | undefined> {
  try {
    const contract = await hre.ethers.getContractAt(contractName, address);
    return await (contract as unknown as { owner(): Promise<string> }).owner();
  } catch {
    return undefined;
  }
}
