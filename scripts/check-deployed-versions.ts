import { execFileSync } from "child_process";
import { readFileSync, readdirSync } from "fs";
import { join } from "path";

import { JsonRpcProvider, type Provider } from "ethers";
import hre from "hardhat";
import {
  TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD,
  TASK_COMPILE_SOLIDITY_RUN_SOLC,
  TASK_COMPILE_SOLIDITY_RUN_SOLCJS,
} from "hardhat/builtin-tasks/task-names";

import {
  loadConfig,
  loadDeployments,
  setMatchesDeployed,
  type Deployment,
} from "./utils/config";
import { IMPL_SLOT, artifactRuntimeHash, chainRuntimeHash, immutablesOf } from "./utils/provenance";

/**
 * Answers one question for every contract this repository deploys: does the source as it stands
 * still produce what is on chain, and does the record say so honestly.
 *
 * Run by hand before a deploy, and by the pull-request gate. Both use this file so the two cannot
 * reach different verdicts — the numbers themselves come from `provenance.ts`, which the deploy
 * scripts write records with.
 *
 *   npx ts-node scripts/check-deployed-versions.ts              every contract, both networks
 *   npx ts-node scripts/check-deployed-versions.ts --fix        recompute matchesDeployed and save
 *   npx ts-node scripts/check-deployed-versions.ts --json       the same as machine-readable output
 *   npx ts-node scripts/check-deployed-versions.ts --offline    skip the chain, rebuild only
 *   npx ts-node scripts/check-deployed-versions.ts --network base
 *
 * Not a hardhat task: `hardhat run` rejects flags it does not know, and the chain half of the work
 * reads two networks in one pass, which a single `--network` could not express anyway.
 */

type Network = {
  chainId: number;
  name: string;
  rpcEnv: string;
  fallbackRpc: string;
  /** Whether a disagreement here fails the run. Only production qualifies — see `gateFails`. */
  gating: boolean;
};

const NETWORKS: Network[] = [
  {
    chainId: 8453,
    name: "base",
    rpcEnv: "BASE_RPC_URL",
    fallbackRpc: "https://mainnet.base.org",
    gating: true,
  },
  {
    chainId: 11155111,
    name: "sepolia",
    rpcEnv: "ETHEREUM_SEPOLIA_RPC_URL",
    fallbackRpc: "https://rpc.sepolia.org",
    gating: false,
  },
];

/**
 * What rebuilding the source at the record's own settings produced.
 *
 * `no-recipe` and `unbuildable` are separate on purpose: the first says the record never carried
 * settings to build with, the second says it does and they do not compile. Only the second is a
 * statement about the code.
 */
type Rebuild =
  | { verdict: "match" | "drift"; hash: string }
  | { verdict: "no-recipe" | "unbuildable" | "no-source"; hash: null; why: string };

type Ancestry = "ok" | "not-ancestor" | "unknown" | "absent";

type Chain =
  | { read: true; liveImpl: string | null; slotOk: boolean | null; codeOk: boolean | null }
  | { read: false; why: string };

type Row = {
  network: Network;
  name: string;
  record: Deployment;
  rebuild: Rebuild;
  /** Whether the stored `matchesDeployed` agrees with the rebuild. */
  claimOk: boolean;
  ancestry: Ancestry;
  chain: Chain;
};

// ── rebuilding ──

/**
 * Build-info holds the exact source set a compilation saw, which is what has to go back into solc:
 * reassembling it from the file tree would mean redoing hardhat's import resolution and getting a
 * different answer the first time a remapping changes.
 *
 * Read once rather than through `artifacts.getBuildInfo`, which reparses the whole file on every
 * call — the same tens of megabytes once per contract.
 */
function loadBuildInfos(): { input: any; output: any }[] {
  const dir = join(__dirname, "..", "artifacts", "build-info");
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
}

/** `v0.8.23+commit.f704f362` is how a record spells it; the compiler downloader wants `0.8.23`. */
function shortSolcVersion(solc: string): string {
  return solc.replace(/^v/, "").split("+")[0];
}

const solcBuilds = new Map<string, any>();

async function solcBuildFor(version: string): Promise<any> {
  const cached = solcBuilds.get(version);
  if (cached) return cached;
  const build = await hre.run(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, {
    quiet: true,
    solcVersion: version,
  });
  solcBuilds.set(version, build);
  return build;
}

/**
 * Compiles one contract at the settings its record carries and hashes the result the same way a
 * deployment is hashed.
 *
 * Only that contract is code-generated, and that is load-bearing rather than an optimisation: a
 * whole-project build at the settings of anything deployed before the yul switch fails outright
 * with "stack too deep", because today's sources need the yul optimizer that those records were
 * built without. Narrowing the output selection keeps codegen to the contract being checked, which
 * is the only one the settings are claimed to describe.
 */
async function rebuildAt(
  name: string,
  build: NonNullable<Deployment["build"]>,
  buildInfos: { input: any; output: any }[]
): Promise<Rebuild> {
  let sourceName: string;
  let contractName: string;
  try {
    const artifact = await hre.artifacts.readArtifact(name);
    sourceName = artifact.sourceName;
    contractName = artifact.contractName;
  } catch {
    return { verdict: "no-source", hash: null, why: "no contract of this name in the repository" };
  }

  const info = buildInfos.find((bi) => bi.input?.sources?.[sourceName]);
  if (!info) {
    return { verdict: "no-source", hash: null, why: `${sourceName} is in no build info — run hardhat compile` };
  }

  const solcBuild = await solcBuildFor(shortSolcVersion(build.solc));

  const input = {
    language: "Solidity",
    sources: info.input.sources,
    settings: {
      optimizer: {
        enabled: build.optimizer.enabled,
        ...(build.optimizer.runs !== null ? { runs: build.optimizer.runs } : {}),
        ...(build.optimizer.details ? { details: build.optimizer.details } : {}),
      },
      ...(build.evmVersion ? { evmVersion: build.evmVersion } : {}),
      outputSelection: { [sourceName]: { [contractName]: ["evm.deployedBytecode.object"] } },
    },
  };

  const output = await hre.run(
    solcBuild.isSolcJs ? TASK_COMPILE_SOLIDITY_RUN_SOLCJS : TASK_COMPILE_SOLIDITY_RUN_SOLC,
    { input, solcJsPath: solcBuild.compilerPath, solcPath: solcBuild.compilerPath, quiet: true }
  );

  const fatal = (output.errors ?? []).filter((e: any) => e.severity === "error");
  if (fatal.length > 0) {
    return { verdict: "unbuildable", hash: null, why: String(fatal[0].message).split("\n")[0].trim() };
  }

  const object = output.contracts?.[sourceName]?.[contractName]?.evm?.deployedBytecode?.object;
  if (!object) {
    return { verdict: "unbuildable", hash: null, why: "solc produced no deployed bytecode" };
  }

  const hash = artifactRuntimeHash("0x" + object);
  return { verdict: "match", hash } as Rebuild;
}

// ── git ──

const git = (args: string[]): string =>
  execFileSync("git", args, { encoding: "utf8", cwd: join(__dirname, "..") }).trim();

/**
 * The branch `deployedFrom` has to be reachable from. `origin/main` is preferred over the local
 * `main`, which on a working clone can sit anywhere, including behind.
 */
function mainRef(): string | null {
  for (const ref of ["origin/main", "main"]) {
    try {
      git(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
      return ref;
    } catch {
      // try the next one
    }
  }
  return null;
}

/**
 * Whether the commit a deployment is attributed to is part of the history it claims to come from.
 *
 * `unknown` rather than a failure when the object is missing: a shallow checkout genuinely cannot
 * answer, and a check that reports "no" when it means "cannot tell" is worse than one that says so.
 */
function ancestryOf(sha: string | null, base: string | null): Ancestry {
  if (!sha) return "absent";
  if (!base) return "unknown";
  try {
    git(["cat-file", "-e", `${sha}^{commit}`]);
  } catch {
    return "unknown";
  }
  try {
    git(["merge-base", "--is-ancestor", sha, base]);
    return "ok";
  } catch {
    return "not-ancestor";
  }
}

// ── chain ──

async function implementationAt(provider: Provider, proxy: string): Promise<string | null> {
  const raw = await provider.getStorage(proxy, IMPL_SLOT);
  const address = "0x" + raw.slice(26);
  return /^0x0{40}$/.test(address) ? null : address;
}

/**
 * The two chain-side questions: does the proxy point where the record says, and is the code at the
 * recorded implementation the code the record hashed.
 *
 * Deliberately hashes the recorded implementation and not the live one. A proxy that has moved on
 * makes `slotOk` false and that is the finding; hashing whatever is live instead would replace it
 * with a second, quieter one.
 */
async function readChain(
  provider: Provider,
  record: Deployment,
  immutables: string[]
): Promise<Chain> {
  try {
    const liveImpl = record.impl === null ? null : await implementationAt(provider, record.proxy);
    const slotOk =
      record.impl === null ? null : liveImpl !== null && liveImpl.toLowerCase() === record.impl.toLowerCase();

    const target = record.impl ?? record.proxy;
    const codeHash = await chainRuntimeHash(provider, target, [target, ...immutables]);
    const codeOk = record.buildHash === null ? null : codeHash === record.buildHash;

    return { read: true, liveImpl, slotOk, codeOk };
  } catch (error: any) {
    return { read: false, why: String(error?.shortMessage ?? error?.message ?? error).split("\n")[0] };
  }
}

// ── verdicts ──

/** Everything that makes a run fail, and only on a gating network. */
function gateFails(row: Row): string[] {
  if (!row.network.gating) return [];
  const problems: string[] = [];
  if (!row.claimOk) {
    problems.push(
      `matchesDeployed says ${row.record.matchesDeployed}, rebuilding says ${row.rebuild.verdict === "match"}`
    );
  }
  if (row.ancestry === "not-ancestor") {
    problems.push(`deployedFrom ${row.record.deployedFrom} is not in the history of main`);
  }
  if (row.chain.read) {
    if (row.chain.slotOk === false) {
      problems.push(`the proxy points at ${row.chain.liveImpl ?? "nothing"}, the record says ${row.record.impl}`);
    }
    if (row.chain.codeOk === false) {
      problems.push("the code at the recorded implementation does not hash to buildHash");
    }
  }
  return problems;
}

// ── output ──

/** Marks a row the run was told not to read, as opposed to one it failed to read. */
const OFFLINE = "--offline";

const SYMBOL: Record<Rebuild["verdict"], string> = {
  match: "=",
  drift: "~",
  "no-recipe": "?",
  unbuildable: "!",
  "no-source": "?",
};

function printTable(network: Network, rows: Row[]): void {
  const label = network.gating ? "blocks a merge" : "informational";
  console.log(`\n${network.name} (${network.chainId}) — ${label}`);
  console.log("-".repeat(96));
  console.log(
    `  ${"contract".padEnd(20)}${"rebuild".padEnd(14)}${"claim".padEnd(8)}${"chain".padEnd(12)}${"deployedFrom".padEnd(16)}note`
  );

  for (const row of rows) {
    const chain = !row.chain.read
      ? row.chain.why === OFFLINE
        ? "—"
        : "unread"
      : row.chain.slotOk === false
        ? "moved"
        : row.chain.codeOk === false
          ? "other code"
          : row.chain.codeOk === null
            ? "—"
            : "ok";

    const from =
      row.record.deployedFrom === null
        ? "—"
        : `${row.record.deployedFrom}${row.ancestry === "ok" ? "" : ` (${row.ancestry})`}`;

    const note =
      row.rebuild.hash === null
        ? row.rebuild.why
        : !row.chain.read && row.chain.why !== OFFLINE
          ? row.chain.why
          : "";

    console.log(
      `  ${row.name.padEnd(20)}` +
        `${(SYMBOL[row.rebuild.verdict] + " " + row.rebuild.verdict).padEnd(14)}` +
        `${(row.claimOk ? "ok" : "WRONG").padEnd(8)}` +
        `${chain.padEnd(12)}` +
        `${from.padEnd(16)}` +
        note
    );
  }
}

// ── main ──

type Options = { fix: boolean; json: boolean; offline: boolean; only: string | null };

function parseArgs(argv: string[]): Options {
  const options: Options = { fix: false, json: false, offline: false, only: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--fix") options.fix = true;
    else if (arg === "--json") options.json = true;
    else if (arg === "--offline") options.offline = true;
    else if (arg === "--network") options.only = argv[++i] ?? null;
    else if (arg.startsWith("--network=")) options.only = arg.slice("--network=".length);
    else throw new Error(`unknown argument ${arg}`);
  }
  return options;
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));

  // The rebuild reads build-info, which only exists once hardhat has compiled. Quiet because the
  // interesting output is the table, and on a warm cache this prints nothing anyway.
  await hre.run("compile", { quiet: true });
  const buildInfos = loadBuildInfos();
  const base = mainRef();

  const networks = options.only
    ? NETWORKS.filter((n) => n.name === options.only || String(n.chainId) === options.only)
    : NETWORKS;
  if (networks.length === 0) throw new Error(`no network called ${options.only}`);

  const all: Row[] = [];

  for (const network of networks) {
    const records = loadDeployments(network.chainId);
    const config = loadConfig(network.chainId);
    const provider = options.offline
      ? null
      : new JsonRpcProvider(process.env[network.rpcEnv] || network.fallbackRpc, network.chainId, {
          staticNetwork: true,
        });

    const rows: Row[] = [];
    for (const [name, record] of Object.entries(records)) {
      const rebuild: Rebuild = record.build
        ? await rebuildAt(name, record.build, buildInfos)
        : { verdict: "no-recipe", hash: null, why: "the record carries no build settings" };

      // `drift` is the same measurement as `match`, told apart only by the comparison, so it is
      // settled here rather than inside the rebuild, which does not know the record.
      const resolved: Rebuild =
        rebuild.hash !== null && rebuild.hash !== record.buildHash
          ? { verdict: "drift", hash: rebuild.hash }
          : rebuild;

      rows.push({
        network,
        name,
        record,
        rebuild: resolved,
        claimOk: record.matchesDeployed === (resolved.verdict === "match"),
        ancestry: ancestryOf(record.deployedFrom, base),
        chain: provider
          ? await readChain(provider, record, immutablesOf(name, config))
          : { read: false, why: OFFLINE },
      });
    }

    if (!options.json) printTable(network, rows);
    all.push(...rows);
  }

  if (options.fix) {
    const corrected = all.filter((row) => !row.claimOk);
    for (const row of corrected) {
      setMatchesDeployed(row.network.chainId, row.name, row.rebuild.verdict === "match");
    }
    if (!options.json) {
      console.log(
        corrected.length === 0
          ? "\n--fix: every matchesDeployed already agreed with the rebuild"
          : `\n--fix: corrected matchesDeployed on ${corrected
              .map((r) => `${r.network.name}/${r.name}`)
              .join(", ")}`
      );
    }
  }

  const failures = all.flatMap((row) => gateFails(row).map((problem) => ({ row, problem })));

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          ok: failures.length === 0,
          contracts: all.map((row) => ({
            network: row.network.name,
            chainId: row.network.chainId,
            name: row.name,
            rebuild: row.rebuild.verdict,
            rebuiltHash: row.rebuild.hash,
            recordedHash: row.record.buildHash,
            matchesDeployed: row.record.matchesDeployed,
            claimOk: row.claimOk,
            deployedFrom: row.record.deployedFrom,
            ancestry: row.ancestry,
            chain: row.chain,
            gating: row.network.gating,
          })),
          failures: failures.map(({ row, problem }) => `${row.network.name}/${row.name}: ${problem}`),
        },
        null,
        2
      )
    );
  } else if (failures.length === 0) {
    console.log("\nNothing on a gating network disagrees with its record.");
  } else {
    console.log("\nDisagreements that block a merge:");
    for (const { row, problem } of failures) console.log(`  ${row.network.name}/${row.name}: ${problem}`);
    console.log(
      "\nA record that contradicts the chain means this repository describes something other than\n" +
        "what is running. Bring the record in step — `--fix` settles matchesDeployed, the rest needs\n" +
        "the deploy scripts, which read the chain."
    );
  }

  // `--fix` writes the corrections it was asked for, so failing on what it just repaired would
  // make the flag unusable. Everything it cannot touch still fails the run.
  const remaining = options.fix
    ? failures.filter(({ problem }) => !problem.startsWith("matchesDeployed says"))
    : failures;
  process.exitCode = remaining.length === 0 ? 0 : 1;
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
