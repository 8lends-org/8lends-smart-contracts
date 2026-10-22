import { execFileSync } from "child_process";
import { existsSync, lstatSync, readFileSync, readdirSync, rmSync, symlinkSync } from "fs";
import { tmpdir } from "os";
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
 *   npx ts-node scripts/check-deployed-versions.ts --blame Fundraise   where it stopped matching
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
  const dir = join(ROOT, "artifacts", "build-info");
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
 * Hashes one contract compiled from the given sources at the given settings, the same way a
 * deployment is hashed.
 *
 * Only that contract is code-generated, and that is load-bearing rather than an optimisation: a
 * whole-project build at the settings of anything deployed before the yul switch fails outright
 * with "stack too deep", because today's sources need the yul optimizer that those records were
 * built without. Narrowing the output selection keeps codegen to the contract being checked, which
 * is the only one the settings are claimed to describe.
 */
async function hashAtSettings(
  sourceName: string,
  contractName: string,
  build: NonNullable<Deployment["build"]>,
  sources: unknown
): Promise<{ hash: string } | { error: string }> {
  const solcBuild = await solcBuildFor(shortSolcVersion(build.solc));

  const input = {
    language: "Solidity",
    sources,
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
  if (fatal.length > 0) return { error: String(fatal[0].message).split("\n")[0].trim() };

  const object = output.contracts?.[sourceName]?.[contractName]?.evm?.deployedBytecode?.object;
  if (!object) return { error: "solc produced no deployed bytecode" };

  return { hash: artifactRuntimeHash("0x" + object) };
}

/** Where a contract's source sits, or null when the repository has no contract of that name. */
async function locate(name: string): Promise<{ sourceName: string; contractName: string } | null> {
  try {
    const artifact = await hre.artifacts.readArtifact(name);
    return { sourceName: artifact.sourceName, contractName: artifact.contractName };
  } catch {
    return null;
  }
}

/**
 * The sources of one compilation narrowed to what the named file actually reaches.
 *
 * solc parses everything it is handed whether or not the output selection asks for it, so handing
 * it the whole project costs a third of the run for files the contract never imports.
 */
function subgraphOf(info: { input: any; output: any }, sourceName: string): Record<string, unknown> {
  const reachable = new Set(transitiveSources(info, sourceName));
  return Object.fromEntries(Object.entries(info.input.sources).filter(([path]) => reachable.has(path)));
}

/**
 * Both networks deploy mostly the same contracts from mostly the same settings, and a rebuild
 * depends on nothing else — so the second network's copy of a pair is answered from here.
 *
 * Keyed before the comparison with `buildHash`, never after: two records can share a build and
 * still have been deployed from different commits, and it is the comparison that tells them apart.
 */
const rebuilds = new Map<string, Rebuild>();

/** The working tree built at the settings of one record. */
async function rebuildAt(
  name: string,
  build: NonNullable<Deployment["build"]>,
  buildInfos: { input: any; output: any }[]
): Promise<Rebuild> {
  const key = `${name}\u0000${JSON.stringify(build)}`;
  const seen = rebuilds.get(key);
  if (seen) return seen;

  const computed = await computeRebuild(name, build, buildInfos);
  rebuilds.set(key, computed);
  return computed;
}

async function computeRebuild(
  name: string,
  build: NonNullable<Deployment["build"]>,
  buildInfos: { input: any; output: any }[]
): Promise<Rebuild> {
  const where = await locate(name);
  if (!where) return { verdict: "no-source", hash: null, why: "no contract of this name in the repository" };

  const info = buildInfos.find((bi) => bi.input?.sources?.[where.sourceName]);
  if (!info) {
    return { verdict: "no-source", hash: null, why: `${where.sourceName} is in no build info — run hardhat compile` };
  }

  const result = await hashAtSettings(
    where.sourceName,
    where.contractName,
    build,
    subgraphOf(info, where.sourceName)
  );
  return "error" in result
    ? { verdict: "unbuildable", hash: null, why: result.error }
    : ({ verdict: "match", hash: result.hash } as Rebuild);
}

// ── git ──

const ROOT = join(__dirname, "..");

const git = (args: string[]): string =>
  execFileSync("git", args, { encoding: "utf8", cwd: ROOT }).trim();

/**
 * Whether the commit a deployment is attributed to is part of the history this run describes.
 *
 * Measured against HEAD, not against main. On a pull request HEAD is the merge result, which is
 * the state being judged everywhere else in this file — and a branch that deployed before merging
 * attributes its record to a commit of its own, reachable from the merge and not yet from main.
 * Comparing with main would fail that record for being exactly what the workflow produces.
 *
 * `unknown` rather than a failure when the object is missing: a shallow checkout genuinely cannot
 * answer, and a check that reports "no" when it means "cannot tell" is worse than one that says so.
 */
function ancestryOf(sha: string | null): Ancestry {
  if (!sha) return "absent";
  try {
    git(["cat-file", "-e", `${sha}^{commit}`]);
  } catch {
    return "unknown";
  }
  try {
    git(["merge-base", "--is-ancestor", sha, "HEAD"]);
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
    problems.push(`deployedFrom ${row.record.deployedFrom} is in no history this checkout has`);
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


// ── blame ──

type Candidate = { sha: string; date: string; subject: string };

/**
 * Every source the contract's compilation actually read, walked from its own file through the
 * import graph.
 *
 * Narrower than "everything under contracts/" on purpose: the walk is what keeps the candidate
 * list to the handful of commits that could have moved this contract's bytecode, instead of every
 * commit that touched any contract.
 */
function transitiveSources(info: { output: any }, sourceName: string): string[] {
  const seen = new Set<string>();
  const queue = [sourceName];
  while (queue.length > 0) {
    const current = queue.shift()!;
    if (seen.has(current)) continue;
    seen.add(current);
    const nodes = info.output?.sources?.[current]?.ast?.nodes ?? [];
    for (const node of nodes) {
      if (node.nodeType === "ImportDirective" && node.absolutePath) queue.push(node.absolutePath);
    }
  }
  return [...seen];
}

/**
 * Commits between the deployment and HEAD that could have changed this contract's bytecode.
 *
 * The compiler settings and the dependency versions are in the filter beside the sources, because
 * either of them moves the bytecode without a line of Solidity changing. Dependencies themselves
 * are not tracked by git, so the lock file stands in for them.
 *
 * Only a filter. What divides matching from drifted is the hash, never the file list.
 */
function candidates(from: string, sources: string[]): Candidate[] {
  const tracked = sources.filter((path) => path.startsWith("contracts/"));
  const output = git([
    "log",
    "--reverse",
    "--format=%H%x09%ad%x09%s",
    "--date=short",
    `${from}..HEAD`,
    "--",
    ...tracked,
    "hardhat.config.ts",
    "package-lock.json",
  ]);
  if (!output) return [];
  return output.split("\n").map((line) => {
    const [sha, date, ...rest] = line.split("\t");
    return { sha, date, subject: rest.join("\t") };
  });
}

/**
 * A throwaway checkout to compile old commits in, reused across all of them — for the checkout
 * and its dependencies, not for compiler output, which `buildInfo` throws away each time.
 *
 * node_modules is borrowed from the main tree by symlink rather than installed, which is right
 * exactly while the lock file is unchanged — and `npm ci` is what happens when it is not. The
 * symlink has to go before that runs, or the install would write through it into the tree we
 * borrowed from.
 */
class Checkout {
  private constructor(
    readonly path: string,
    private readonly lockOfMainTree: string
  ) {}

  static create(): Checkout {
    const path = join(tmpdir(), `deployed-blame-${process.pid}`);
    rmSync(path, { recursive: true, force: true });
    execFileSync("git", ["worktree", "add", "--detach", path, "HEAD"], { cwd: ROOT, stdio: "ignore" });
    return new Checkout(path, readFileSync(join(ROOT, "package-lock.json"), "utf8"));
  }

  moveTo(sha: string): void {
    execFileSync("git", ["checkout", "--detach", "--force", sha], { cwd: this.path, stdio: "ignore" });

    const lock = join(this.path, "package-lock.json");
    const modules = join(this.path, "node_modules");
    const borrowed = existsSync(modules) && lstatSync(modules).isSymbolicLink();

    if (readFileSync(lock, "utf8") === this.lockOfMainTree) {
      if (!borrowed) {
        rmSync(modules, { recursive: true, force: true });
        symlinkSync(join(ROOT, "node_modules"), modules);
      }
      return;
    }

    console.log(`    (package-lock.json differs here — installing, this one is slow)`);
    if (borrowed) rmSync(modules);
    execFileSync("npm", ["ci"], { cwd: this.path, stdio: "ignore" });
  }

  /**
   * Build info for the commit in hand, produced by that commit's own hardhat config.
   *
   * Compiled from scratch every time. Left alone, the previous commit's build info stays in the
   * directory and hardhat skips the work whenever its cache calls the tree unchanged — and then
   * this reads a file describing some other commit. The verdict that comes out of that looks
   * entirely reasonable, which is what makes it worth the extra twenty seconds.
   */
  buildInfo(sourceName: string): { input: any; output: any } | null {
    rmSync(join(this.path, "artifacts"), { recursive: true, force: true });
    rmSync(join(this.path, "cache"), { recursive: true, force: true });
    execFileSync("npx", ["hardhat", "compile"], { cwd: this.path, stdio: "ignore" });

    const dir = join(this.path, "artifacts", "build-info");
    if (!existsSync(dir)) return null;
    for (const file of readdirSync(dir).filter((f) => f.endsWith(".json"))) {
      const info = JSON.parse(readFileSync(join(dir, file), "utf8"));
      if (info.input?.sources?.[sourceName]) return info;
    }
    return null;
  }

  remove(): void {
    git(["worktree", "remove", "--force", this.path]);
  }
}

/**
 * Where a contract stopped reproducing its deployment, as a list rather than a single commit.
 *
 * A list because the property is not monotonic: a change and its revert both appear, and a bisect
 * would report whichever side it happened to land on. Walking the candidates in order shows the
 * contract leaving the deployed code and, if it did, coming back.
 */
async function blame(network: Network, name: string): Promise<number> {
  const record = loadDeployments(network.chainId)[name];
  if (!record) throw new Error(`${name} has no record on ${network.name}`);
  if (!record.deployedFrom) {
    console.log(`${name} on ${network.name}: deployedFrom is empty, so there is no range to walk.`);
    return 1;
  }
  if (!record.build || !record.buildHash) {
    console.log(`${name} on ${network.name}: the record carries no build settings to rebuild with.`);
    return 1;
  }

  const where = await locate(name);
  if (!where) throw new Error(`no contract called ${name} in the repository`);

  await hre.run("compile", { quiet: true });
  const info = loadBuildInfos().find((bi) => bi.input?.sources?.[where.sourceName]);
  if (!info) throw new Error(`${where.sourceName} is in no build info`);

  const commits = candidates(record.deployedFrom, transitiveSources(info, where.sourceName));

  console.log(
    `\n${name} on ${network.name} — deployed from ${record.deployedFrom}` +
      `${record.deployedAt ? ` (${record.deployedAt})` : ""}`
  );
  if (commits.length === 0) {
    console.log("  Nothing since has touched its sources, its compiler settings or the lock file.");
    return 0;
  }
  console.log(`  ${commits.length} commit${commits.length === 1 ? "" : "s"} could have moved its bytecode\n`);

  const checkout = Checkout.create();
  const verdicts: boolean[] = [];
  try {
    for (const commit of commits) {
      checkout.moveTo(commit.sha);
      // Narrowed for the same reason the table narrows: an unrelated file whose pragma rejects
      // this record's compiler would otherwise fail the whole commit and read as "does not build".
      const info = checkout.buildInfo(where.sourceName);
      const result = info
        ? await hashAtSettings(
            where.sourceName,
            where.contractName,
            record.build,
            subgraphOf(info, where.sourceName)
          )
        : { error: "the contract is in no build info at this commit" };

      const matches = "hash" in result && result.hash === record.buildHash;
      verdicts.push(matches);

      const previous = verdicts.length > 1 ? verdicts[verdicts.length - 2] : true;
      const marker =
        "error" in result
          ? `← does not build: ${result.error}`
          : matches === previous
            ? ""
            : matches
              ? "← back to the deployed code"
              : "← first divergence";

      console.log(
        (
          `  ${commit.sha.slice(0, 7)}  ${commit.date}  ${commit.subject.slice(0, 52).padEnd(54)}` +
          `${matches ? "matches" : "drifted"}  ${marker}`
        ).trimEnd()
      );
    }
  } finally {
    checkout.remove();
  }

  const now = verdicts[verdicts.length - 1];
  console.log(`\n  HEAD ${now ? "reproduces the deployed code" : "does not reproduce the deployed code"}.`);
  return 0;
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

type Options = { fix: boolean; json: boolean; offline: boolean; only: string | null; blame: string | null };

/**
 * The argument a flag takes. A flag left without one is a mistake worth stopping on rather than
 * absorbing: `--blame` with nothing after it would otherwise run the whole table instead, which
 * looks like a working command.
 */
function value(argv: string[], at: number, flag: string): string {
  const given = argv[at];
  if (given === undefined || given.startsWith("--")) throw new Error(`${flag} needs a value`);
  return given;
}

function parseArgs(argv: string[]): Options {
  const options: Options = { fix: false, json: false, offline: false, only: null, blame: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--fix") options.fix = true;
    else if (arg === "--json") options.json = true;
    else if (arg === "--offline") options.offline = true;
    else if (arg === "--network") options.only = value(argv, ++i, "--network");
    else if (arg.startsWith("--network=")) options.only = arg.slice("--network=".length);
    else if (arg === "--blame") options.blame = value(argv, ++i, "--blame");
    else if (arg.startsWith("--blame=")) options.blame = arg.slice("--blame=".length);
    else throw new Error(`unknown argument ${arg}`);
  }
  return options;
}

function networksFrom(only: string | null): Network[] {
  const chosen = only
    ? NETWORKS.filter((n) => n.name === only || String(n.chainId) === only)
    : NETWORKS;
  if (chosen.length === 0) throw new Error(`no network called ${only}`);
  return chosen;
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));

  // One contract on one network: walking history is the whole job, and the table would say
  // nothing the walk does not. Production by default, since that is the record worth explaining.
  if (options.blame !== null) {
    const network = networksFrom(options.only ?? "base")[0];
    process.exitCode = await blame(network, options.blame);
    return;
  }

  // The rebuild reads build-info, which only exists once hardhat has compiled. Quiet because the
  // interesting output is the table, and on a warm cache this prints nothing anyway.
  await hre.run("compile", { quiet: true });
  const buildInfos = loadBuildInfos();

  const networks = networksFrom(options.only);

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
        ancestry: ancestryOf(record.deployedFrom),
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
