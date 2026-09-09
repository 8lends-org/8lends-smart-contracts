import { execSync } from "child_process";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import type { Provider } from "ethers";
import { keccak256 } from "ethers";

import type { Deployment } from "./config";

/**
 * Fills in a deployments/<chainId>.json record from primary data rather than from what a script
 * was told. Kept apart from the deploy scripts because the pull-request check has to arrive at
 * exactly the same numbers to be able to compare them — `chainRuntimeHash` and
 * `artifactRuntimeHash` are the two halves of that comparison.
 */

const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

/**
 * Drops the CBOR metadata trailer, whose last two bytes hold its own length.
 *
 * It has to go before any comparison: it carries a hash of the source text and of the compiler
 * settings, so two builds of the same code differ there for reasons that say nothing about the code.
 */
function stripMetadata(hex: string): Buffer {
  const bytes = Buffer.from(hex.replace(/^0x/, ""), "hex");
  if (bytes.length < 2) return bytes;
  const length = bytes.readUInt16BE(bytes.length - 2);
  return length + 2 <= bytes.length ? bytes.subarray(0, bytes.length - (length + 2)) : bytes;
}

/**
 * Zeroes every occurrence of the given addresses.
 *
 * Masking is by VALUE, not by the offsets in `immutableReferences`: those offsets belong to the
 * build in hand, and a deployment that has drifted from it need not put its immutables in the same
 * places. A compiled artifact already carries zeroes there, so masking the chain's copy is what
 * makes the two comparable.
 */
function maskAddresses(code: Buffer, addresses: (string | null | undefined)[]): Buffer {
  const out = Buffer.from(code);
  for (const address of addresses) {
    if (!address) continue;
    const needle = Buffer.from(address.replace(/^0x/, ""), "hex");
    for (let from = 0; ; ) {
      const at = out.indexOf(needle, from);
      if (at < 0) break;
      out.fill(0, at, at + needle.length);
      from = at + needle.length;
    }
  }
  return out;
}

/**
 * The `buildHash` of code as deployed: metadata dropped, immutables masked. Null when the address
 * holds no code.
 *
 * `immutables` are the values to mask — a UUPS implementation's own address, which it keeps at
 * three sites, or whatever else a given contract bakes in.
 */
export async function chainRuntimeHash(
  provider: Provider,
  address: string,
  immutables: (string | null | undefined)[] = []
): Promise<string | null> {
  const code = await provider.getCode(address);
  if (!code || code === "0x") return null;
  return keccak256(maskAddresses(stripMetadata(code), immutables));
}

/**
 * The same hash for a compiled artifact, whose immutables are already zeroes.
 *
 * Refuses unlinked bytecode outright. No contract here needs library linking today, but if one
 * ever does its artifact carries `__$<hash>$__` placeholders, and those are not hex: parsing would
 * stop at the first `_` and hash a silently truncated prefix. A wrong hash that looks well-formed
 * is the one failure this file cannot afford.
 */
export function artifactRuntimeHash(deployedBytecode: string): string {
  if (deployedBytecode.includes("__$")) {
    throw new Error("artifact needs library linking — link it before hashing, or the hash is meaningless");
  }
  return keccak256(stripMetadata(deployedBytecode));
}

type SolcSettings = {
  optimizer?: { enabled?: boolean; runs?: number; details?: { yul?: boolean } };
  evmVersion?: string;
};

const toBuild = (
  solc: string,
  settings: SolcSettings,
  fallbackDetails?: { yul?: boolean }
): Deployment["build"] => {
  const optimizer = settings.optimizer ?? {};
  const yul = optimizer.details ?? fallbackDetails;
  return {
    solc,
    optimizer: {
      enabled: !!optimizer.enabled,
      runs: optimizer.runs ?? null,
      details: yul ? { yul: !!yul.yul } : null,
    },
    evmVersion: settings.evmVersion ?? null,
  };
};

/**
 * The compiler settings as the block explorer publishes them.
 *
 * Preferred over the local artifact because it is the copy an outsider can act on: anyone
 * reproducing this deployment starts from the verified source, not from our node_modules. It is
 * also the source the historical records in this file were filled from, so preferring it keeps one
 * meaning for the field across old and new entries.
 *
 * Returns null when the address is unverified, when there is no API key, or when the explorer does
 * not answer — all ordinary conditions, and all of them fall through to the artifact.
 */
async function explorerBuildSettings(
  chainId: bigint | number | string,
  address: string
): Promise<Deployment["build"] | null> {
  const key = process.env.ETHERSCAN_API_KEY;
  if (!key) return null;

  const url =
    `https://api.etherscan.io/v2/api?chainid=${chainId}&module=contract&action=getsourcecode` +
    `&address=${address}&apikey=${key}`;

  let entry: Record<string, string>;
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(15_000) });
    const body = (await response.json()) as { status?: string; result?: Record<string, string>[] };
    entry = body.result?.[0] ?? {};
    if (body.status !== "1" || !entry.SourceCode || !entry.CompilerVersion) return null;
  } catch {
    return null;
  }

  // A standard-json verification is stored double-braced and carries the whole settings block,
  // including optimizer.details. A flattened one only exposes the handful of columns below, so
  // `details` comes back null there and the artifact has to supply the yul flag.
  const settings: SolcSettings = entry.SourceCode.startsWith("{{")
    ? (JSON.parse(entry.SourceCode.slice(1, -1)).settings ?? {})
    : {
        optimizer: { enabled: entry.OptimizationUsed === "1", runs: Number(entry.Runs) || undefined },
        evmVersion: entry.EVMVersion && entry.EVMVersion !== "Default" ? entry.EVMVersion : undefined,
      };

  return toBuild(entry.CompilerVersion, settings);
}

/**
 * The compiler settings that actually produced the local artifact, read out of its build info
 * rather than out of the hardhat config: if the config leaves `evmVersion` unset, the config
 * cannot say which one solc picked, while the metadata solc emitted always can.
 *
 * The two halves of the build info are both needed. Metadata is authoritative for `evmVersion`
 * and for the optimizer being on and its `runs`, but solc never writes `optimizer.details` into
 * it — so the `yul` flag, the one setting that splits everything deployed before August 2026 from
 * everything after, survives only in the input that hardhat handed to the compiler.
 */
async function artifactBuildSettings(
  hre: HardhatRuntimeEnvironment,
  fqn: string
): Promise<Deployment["build"] | null> {
  const info = await hre.artifacts.getBuildInfo(fqn);
  if (!info) return null;

  const [sourceName, name] = fqn.split(":");
  const compiled = info.output?.contracts?.[sourceName]?.[name] as { metadata?: string } | undefined;
  const input = (info.input.settings ?? {}) as SolcSettings;
  const settings: SolcSettings = compiled?.metadata ? JSON.parse(compiled.metadata).settings : input;

  return toBuild(`v${info.solcLongVersion}`, settings, input.optimizer?.details);
}

/**
 * Build settings, explorer first and the artifact behind it.
 *
 * Not a plain fallback but a merge, because the two sources are incomplete in different places: a
 * flattened verification publishes neither `optimizer.details` nor an `evmVersion`, while the
 * artifact always has both. So the explorer sets the shape and the artifact fills the holes it
 * leaves — and if the explorer knows nothing about the address, the artifact stands alone.
 */
async function resolveBuild(
  hre: HardhatRuntimeEnvironment,
  fqn: string,
  chainId: bigint | number | string,
  address: string
): Promise<{ build: Deployment["build"] | null; from: "explorer" | "artifact" | "none"; filled: string[] }> {
  const [explorer, artifact] = await Promise.all([
    explorerBuildSettings(chainId, address),
    artifactBuildSettings(hre, fqn),
  ]);

  if (!explorer) return { build: artifact, from: artifact ? "artifact" : "none", filled: [] };
  if (!artifact) return { build: explorer, from: "explorer", filled: [] };

  const filled: string[] = [];
  const build = { ...explorer, optimizer: { ...explorer.optimizer } };
  if (build.optimizer.runs === null) {
    build.optimizer.runs = artifact.optimizer.runs;
    filled.push("runs");
  }
  if (build.optimizer.details === null) {
    build.optimizer.details = artifact.optimizer.details;
    filled.push("optimizer.details");
  }
  if (build.evmVersion === null) {
    build.evmVersion = artifact.evmVersion;
    filled.push("evmVersion");
  }
  return { build, from: "explorer", filled };
}

/**
 * Current commit, plus whether anything the bytecode depends on is uncommitted.
 *
 * Deliberately narrower than `git status`: an unrelated new document in the working tree would
 * otherwise raise the flag on every run, and a warning that always fires is one nobody reads. The
 * paths listed are the ones that change the output — the sources, the compiler settings, and the
 * dependency versions. Untracked files count too, but only under contracts/, where a new .sol can
 * reach the build.
 */
function gitHead(): { commit: string; dirty: boolean } {
  const git = (args: string): string => execSync(`git ${args}`, { encoding: "utf8" }).trim();
  return {
    commit: git("rev-parse --short HEAD"),
    dirty: git("status --porcelain -- contracts hardhat.config.ts package-lock.json").length > 0,
  };
}

/**
 * First block at which the proxy pointed at this implementation — the moment the code went live,
 * which is what `deployedAt` records and which is not when the implementation was created: an
 * upgrade that goes through a Safe sits between the two.
 *
 * Found by bisecting the implementation slot rather than by reading `Upgraded` events, because
 * every RPC we use answers historical state queries while most of them cap `eth_getLogs` to a
 * handful of blocks.
 */
async function findWentLiveBlock(provider: Provider, proxy: string, impl: string): Promise<number | null> {
  const target = impl.toLowerCase();
  const pointsHere = async (blockTag: number): Promise<boolean> => {
    const raw = await provider.getStorage(proxy, IMPL_SLOT, blockTag);
    return "0x" + raw.slice(26).toLowerCase() === target;
  };

  let high = await provider.getBlockNumber();
  if (!(await pointsHere(high))) return null; // already upgraded past this implementation

  // Probe the far end before bisecting: a node without archive depth throws here, and an empty
  // date is better than one bisected out of partial history.
  let low = 0;
  try {
    await pointsHere(low);
  } catch {
    return null;
  }

  while (high - low > 1) {
    const mid = Math.floor((low + high) / 2);
    if (await pointsHere(mid)) high = mid;
    else low = mid;
  }
  return high;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** `deployedAt` as the rest of the file spells it: Aug-19-2026, in UTC. */
function formatDeployedAt(unixSeconds: number): string {
  const d = new Date(unixSeconds * 1000);
  return `${MONTHS[d.getUTCMonth()]}-${String(d.getUTCDate()).padStart(2, "0")}-${d.getUTCFullYear()}`;
}

/**
 * Assembles a full record for an implementation that is live behind `proxy`.
 *
 * `deployedFrom` is only filled when the build actually reproduces the deployed code. Recording
 * HEAD because HEAD happens to be checked out would be a guess, and this file is meant to be
 * checkable — an attribution nothing verified is worse than an empty field.
 */
export async function describeDeployment(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  proxy: string,
  impl: string
): Promise<Deployment & { notes: string[] }> {
  const notes: string[] = [];
  const provider = hre.ethers.provider;
  const artifact = await hre.artifacts.readArtifact(contractName);
  const fqn = `${artifact.sourceName}:${artifact.contractName}`;

  const buildHash = await chainRuntimeHash(provider, impl, [impl]);
  const matchesDeployed = buildHash !== null && artifactRuntimeHash(artifact.deployedBytecode) === buildHash;
  if (buildHash === null) {
    notes.push(`no code at ${impl} — buildHash left empty`);
  } else if (!matchesDeployed) {
    notes.push(
      "the current build does not reproduce the deployed code, so deployedFrom is left empty; " +
        "the working tree is not what was deployed"
    );
  }

  // From the provider rather than from network.config, where chainId is optional and often unset.
  const { chainId } = await provider.getNetwork();
  const resolved = await resolveBuild(hre, fqn, chainId, impl);

  // The field promises settings that reproduce buildHash. A verified source on the explorer is
  // that by construction — it was checked against this very address. The local artifact is only
  // that while the local build matches, so when it does not, its settings describe the working
  // tree and not the deployment, and recording them would put a recipe there that does not work.
  let build = resolved.build;
  if (build && resolved.from === "artifact" && !matchesDeployed) {
    notes.push(
      "build left empty: the address is not verified on the explorer, and the local settings " +
        "do not reproduce the deployed code, so they are not a recipe for it"
    );
    build = null;
  } else if (!build) {
    notes.push("neither the explorer nor the artifact could give build settings — build left empty");
  } else if (resolved.from === "explorer") {
    const extra = resolved.filled.length ? `, with ${resolved.filled.join(" and ")} from the artifact` : "";
    notes.push(`build settings taken from the explorer${extra}`);
  } else {
    notes.push("build settings taken from the local artifact");
  }

  let deployedFrom: string | null = null;
  if (matchesDeployed) {
    const { commit, dirty } = gitHead();
    deployedFrom = commit;
    if (dirty) {
      notes.push(
        `recorded deployedFrom ${commit}, but the tree has uncommitted changes — commit them, ` +
          "or the reference points at something that was never built"
      );
    }
  }

  let deployedAt: string | null = null;
  const block = await findWentLiveBlock(provider, proxy, impl);
  if (block === null) {
    notes.push("could not locate the block where the proxy started pointing here — deployedAt left empty");
  } else {
    const header = await provider.getBlock(block);
    if (header) deployedAt = formatDeployedAt(header.timestamp);
  }

  return { proxy, impl, buildHash, matchesDeployed, deployedFrom, deployedAt, build, notes };
}
