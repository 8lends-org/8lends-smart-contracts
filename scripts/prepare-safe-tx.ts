import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile } from "./utils/helpers";
import { buildTransaction, findAbiFunction, isDryRun, signatureOf, tryReadOwner, writeBatch } from "./utils/safe-batch";
import { requireRealNetwork } from "./utils/network-guard";
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
 *              omitted to reuse METHOD. Overrides ARGS when present.
 *
 *   CONTRACT=Fundraise METHOD=setAmlGateway ARGS='["@EscrowFactory"]'
 *   CONTRACT=Fundraise METHOD=setAmlGateway ARGS='["0x0000000000000000000000000000000000000000"]'
 *   CONTRACT=ManagerRegistry METHOD=setOperatorStatus ARGS='["0x6E9d…C28", true]'
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
  if (!contractName) usage("CONTRACT is not set.");
  const callsEnv = process.env.CALLS || undefined;
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
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = (await readJsonFile(filePath)) as Record<string, unknown>;

  const override = process.env.ADDRESS;
  const target = override ?? config[contractName];
  if (typeof target !== "string") {
    throw new Error(
      `${contractName} not found in ${filePath}. Pass ADDRESS=0x… if the config key differs ` +
      `from the artifact name.`
    );
  }
  if (!ethers.isAddress(target)) throw new Error(`Not an address: ${target}`);

  const artifact = await hre.artifacts.readArtifact(contractName);
  const iface = new ethers.Interface(artifact.abi as never);

  // Either one call from METHOD/ARGS, or several from CALLS.
  let calls: { method: string; args: unknown[] }[];
  if (callsEnv) {
    try {
      calls = JSON.parse(callsEnv).map((c: { method?: string; args: unknown[] }) => ({
        method: c.method ?? (method as string),
        args: c.args,
      }));
    } catch {
      usage(`CALLS is not valid JSON: ${callsEnv}`);
    }
    if (!Array.isArray(calls) || calls.length === 0) usage("CALLS must be a non-empty JSON array.");
  } else {
    calls = [{ method: method as string, args }];
  }

  // Build first: it checks the argument count and gives a clearer message than the encoder. The
  // encoding itself is not used in the batch — Safe does it — but it validates argument types here
  // rather than after the file has been circulated for signatures.
  const built = calls.map((c) => {
    const e = findAbiFunction(artifact.abi as unknown[], c.method);
    const r = c.args.map((x) => resolveArg(x, config));
    const tx = buildTransaction(target, e, r);
    iface.encodeFunctionData(signatureOf(e), r);
    return { entry: e, resolved: r, tx };
  });
  const entry = built[0].entry;

  const owner = await tryReadOwner(contractName, target);

  console.log(`\nNetwork:  ${net.name} (chainId ${net.chainId})`);
  console.log(`Target:   ${contractName} at ${target}`);
  console.log(`Owner:    ${owner ?? "unknown (no owner() or call unavailable)"}`);
  built.forEach((b, n) => {
    const prefix = built.length > 1 ? `Call ${n + 1}/${built.length}:` : "Call:    ";
    console.log(`${prefix} ${signatureOf(b.entry)}`);
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
    .map((b) => `${b.entry.name}(${b.resolved.map((v) => String(v)).join(", ")})`)
    .join("; ");
  const fileName = writeBatch({
    chainId: net.chainId,
    name: built.length > 1 ? `${contractName}: ${built.length} calls` : `${contractName}.${entry.name}`,
    description: `${contractName} ${target}: ${description}`,
    safeAddress: owner ?? "",
    transactions: built.map((b) => b.tx),
    fileStem: `safe-tx-${contractName}-${entry.name}-${net.chainId}`,
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
