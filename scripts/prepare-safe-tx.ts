import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { buildTransaction, findAbiFunction, isDryRun, signatureOf, tryReadOwner, writeBatch } from "./utils/safe-batch";
import { requireRealNetwork } from "./utils/network-guard";
import { configPath, loadConfig } from "./utils/config";

dotenv.config();

/**
 * Writes a Safe Transaction Builder batch for one owner-only call — the generic replacement for
 * per-method scripts. Nothing is deployed and nothing is sent; the config is only read.
 *
 * Usage: CONTRACT=<Name> METHOD=<method> ARGS='<json array>' \
 *          npx hardhat run scripts/prepare-safe-tx.ts --network <network>
 *
 * ADDRESS=0x…  overrides the config lookup, for contracts whose config key differs from the
 *              artifact name (the 8LNDS token is `token` in the config, `Token` as an artifact).
 * CALLS='[{"method":"mint","args":[…]}, …]'  puts several calls into one batch; `method` may be
 *              omitted to reuse METHOD. Overrides ARGS when present. A call may also carry its own
 *              `contract`, so one batch can touch several contracts — an upgrade of two contracts
 *              that must go live together. CONTRACT is then only the default for calls without one.
 *
 *   CONTRACT=Fundraise METHOD=setAmlGateway ARGS='["@EscrowFactory"]'
 *   CONTRACT=Fundraise METHOD=setAmlGateway ARGS='["0x0000000000000000000000000000000000000000"]'
 *   CONTRACT=ManagerRegistry METHOD=setOperatorStatus ARGS='["0x6E9d…C28", true]'
 *   METHOD=upgradeToAndCall CALLS='[{"contract":"Fundraise","args":["0xb551…","0x"]},
 *                                   {"contract":"Market","args":["0xB7E0…","0x"]}]'
 *
 * CONTRACT is both the config key of the proxy and the artifact name. ARGS is a JSON array, so
 * types come out right (true is a bool, "0x…" a string). A "@Key" argument is looked up in the
 * network config, which keeps addresses out of the command line. METHOD takes a full
 * `name(type,...)` signature when the name is overloaded.
 */

/** Resolves "@ConfigKey" against the network config; anything else is passed through. */
function resolveArg(arg: unknown, config: Record<string, unknown>): unknown {
  if (typeof arg !== "string" || !arg.startsWith("@")) return arg;
  const key = arg.slice(1);
  const value = config[key];
  if (typeof value !== "string") {
    throw new Error(`${arg}: '${key}' is not an address in the network config`);
  }
  return value;
}

/**
 * The Safe that will execute the batch. Taken from owner() where there is one; a role-gated
 * contract has none, and then SAFE= has to supply it. Empty is refused rather than written: the
 * Transaction Builder uses this field to warn that a batch belongs to a different Safe, and a blank
 * one loses that warning without saying so.
 */
function requireSafeAddress(owner: string | undefined, target: string): string {
  const safe = process.env.SAFE || owner;
  if (!safe) {
    throw new Error(
      `${target} has no owner(), so the executing Safe cannot be inferred. ` +
        `Pass SAFE=0x… — without it the batch would carry no createdFromSafeAddress ` +
        `and the Transaction Builder could not tell it was built for another Safe.`
    );
  }
  return safe;
}

/**
 * File name for the batch. A multi-call batch named after its first call reads as if it did only
 * that — the upgrade hiding behind a grantRole is exactly the kind of thing a reviewer skips. Up to
 * three distinct methods are spelled out; beyond that the count is honest enough.
 */
function fileStemFor(contractName: string, methods: string[], chainId: bigint | number): string {
  const distinct = [...new Set(methods)];
  const part = distinct.length <= 3 ? distinct.join("-") : `${distinct.length}-calls`;
  return `safe-tx-${contractName}-${part}-${chainId}`;
}

function usage(message: string): never {
  console.error(`${message}\n`);
  console.error("  CONTRACT=<Name> METHOD=<method> ARGS='<json array>' \\");
  console.error("    npx hardhat run scripts/prepare-safe-tx.ts --network <network>\n");
  console.error("  e.g. CONTRACT=Fundraise METHOD=setAmlGateway ARGS='[\"@EscrowFactory\"]'");
  console.error("       CONTRACT=ManagerRegistry METHOD=setOperatorStatus ARGS='[\"0xabc…\", true]'\n");
  console.error("CONTRACT is the config key and artifact name. '@Key' args are read from the config.");
  process.exit(1);
}

async function main() {
  await requireRealNetwork();
  // Empty values are treated as absent: .env carries these keys as blank placeholders.
  const contractName = process.env.CONTRACT || undefined;
  const method = process.env.METHOD || undefined;
  const callsEnv = process.env.CALLS || undefined;
  if (!contractName && !callsEnv) usage("CONTRACT is not set.");
  if (!method && !callsEnv) usage("METHOD is not set (or pass CALLS).");

  let args: unknown[];
  try {
    // `||` not `??`: an empty ARGS= line in .env must count as absent, not as invalid JSON.
    args = JSON.parse(process.env.ARGS || "[]");
  } catch {
    usage(`ARGS is not valid JSON: ${process.env.ARGS}`);
  }
  if (!Array.isArray(args)) usage("ARGS must be a JSON array.");

  const net = await ethers.provider.getNetwork();
  const filePath = configPath(net.chainId);
  const config = (loadConfig(net.chainId)) as Record<string, unknown>;

  /** Proxy address of a contract: ADDRESS for the default contract, the config for the rest. */
  const targetOf = (name: string): string => {
    const override = name === contractName ? process.env.ADDRESS : undefined;
    const target = override ?? config[name];
    if (typeof target !== "string") {
      throw new Error(
        `${name} not found in ${filePath}. Pass ADDRESS=0x… if the config key differs ` +
        `from the artifact name.`
      );
    }
    if (!ethers.isAddress(target)) throw new Error(`Not an address: ${target}`);
    return target;
  };

  // Either one call from METHOD/ARGS, or several from CALLS.
  let calls: { contract: string; method: string; args: unknown[] }[];
  if (callsEnv) {
    try {
      calls = JSON.parse(callsEnv).map((c: { contract?: string; method?: string; args: unknown[] }) => ({
        contract: c.contract ?? (contractName as string),
        method: c.method ?? (method as string),
        args: c.args,
      }));
    } catch {
      usage(`CALLS is not valid JSON: ${callsEnv}`);
    }
    if (!Array.isArray(calls) || calls.length === 0) usage("CALLS must be a non-empty JSON array.");
    if (calls.some((c) => !c.contract)) usage("A call in CALLS has no contract and CONTRACT is not set.");
    if (calls.some((c) => !c.method)) usage("A call in CALLS has no method and METHOD is not set.");
  } else {
    calls = [{ contract: contractName as string, method: method as string, args }];
  }

  // Build first: it checks the argument count and gives a clearer message than the encoder. The
  // encoding itself is not used in the batch — Safe does it — but it validates argument types here
  // rather than after the file has been circulated for signatures.
  const built = await Promise.all(calls.map(async (c) => {
    const target = targetOf(c.contract);
    const artifact = await hre.artifacts.readArtifact(c.contract);
    const e = findAbiFunction(artifact.abi as unknown[], c.method);
    const r = c.args.map((x) => resolveArg(x, config));
    const tx = buildTransaction(target, e, r);
    new ethers.Interface(artifact.abi as never).encodeFunctionData(signatureOf(e), r);
    return { contract: c.contract, target, entry: e, resolved: r, tx };
  }));
  const entry = built[0].entry;
  const contracts = [...new Set(built.map((b) => b.contract))];

  // One batch executes from one Safe, so every contract in it has to be owned by that Safe.
  const owners = await Promise.all(contracts.map((name) => tryReadOwner(name, targetOf(name))));
  const owner = owners[0];
  if (owners.some((o) => o?.toLowerCase() !== owner?.toLowerCase())) {
    throw new Error(
      `Contracts in one batch have different owners: ` +
      contracts.map((name, i) => `${name} ${owners[i] ?? "unknown"}`).join(", ")
    );
  }

  console.log(`\nNetwork:  ${net.name} (chainId ${net.chainId})`);
  contracts.forEach((name) => console.log(`Target:   ${name} at ${targetOf(name)}`));
  console.log(`Owner:    ${owner ?? "unknown (no owner() or call unavailable)"}`);
  built.forEach((b, n) => {
    const prefix = built.length > 1 ? `Call ${n + 1}/${built.length}:` : "Call:    ";
    const on = contracts.length > 1 ? ` on ${b.contract}` : "";
    console.log(`${prefix} ${signatureOf(b.entry)}${on}`);
    b.resolved.forEach((value, i) => {
      const original = calls[n].args[i];
      const via = original !== value ? `  ← ${original}` : "";
      console.log(`  ${b.entry.inputs[i].name || `arg${i}`}: ${String(value)}${via}`);
    });
  });
  if (isDryRun()) {
    console.log("\nDRY RUN on the in-process fork. Pass --network base (or sepolia) for a submittable batch.");
  }

  const description = built
    .map((b) => `${b.contract} ${b.target}: ${b.entry.name}(${b.resolved.map((v) => String(v)).join(", ")})`)
    .join("; ");
  const label = contracts.join(" + ");
  const fileName = writeBatch({
    chainId: net.chainId,
    name: built.length > 1 ? `${label}: ${built.length} calls` : `${label}.${entry.name}`,
    description,
    safeAddress: requireSafeAddress(owner, built.map((b) => b.target).join(", ")),
    transactions: built.map((b) => b.tx),
    fileStem: fileStemFor(contracts.join("-"), built.map((b) => b.entry.name), net.chainId),
  });

  console.log(`\nBatch written to ${fileName}`);
  if (!isDryRun()) {
    console.log("Safe → Apps → Transaction Builder → drag the file in → review → Create batch.\n");
  } else {
    console.log("Dry run: this file must not be submitted.\n");
  }
}

main().catch((error) => {
  console.error(`\nError: ${error.message}`);
  process.exit(1);
});
