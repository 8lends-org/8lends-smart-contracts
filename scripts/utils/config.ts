import { readFileSync, writeFileSync } from "fs";
import { join } from "path";

const ROOT = join(__dirname, "..", "..");

/**
 * Network data lives in two files, split by how it behaves rather than by who reads it:
 *
 *   deployments/<chainId>.json  contracts this repo deploys — addresses change on every upgrade,
 *                              and each record carries the code it was built from
 *   config/<chainId>.json      external references and parameters — USDC, routers, oracle feeds
 *
 * Readers do not need to know about the split: `loadConfig` returns them merged in the old flat
 * shape, so `config.Fundraise` and `config.Fundraise_impl` still resolve. Only code that wants to
 * know what a deployment was built from reaches for `loadDeployments`.
 */

/** One contract in deployments/<chainId>.json. Field semantics are documented in the file's _meta. */
export interface Deployment {
  proxy: string;
  impl: string | null;
  /**
   * Implementation deployed but not yet live: the Safe has still to execute the upgrade batch.
   * Optional because it is a passing state — the key is absent whenever nothing is queued.
   */
  pendingImpl?: string;
  buildHash: string | null;
  /** Recomputed, never authored: HEAD built with `build` reproduces `buildHash`. False when `build` is null. */
  matchesDeployed: boolean;
  deployedFrom: string | null;
  deployedAt: string | null;
  build: {
    solc: string;
    optimizer: { enabled: boolean; runs: number | null; details: { yul: boolean } | null };
    evmVersion: string | null;
  } | null;
}

export function configPath(chainId: bigint | number | string): string {
  return join(ROOT, "config", `${chainId}.json`);
}

function deploymentsPath(chainId: bigint | number | string): string {
  return join(ROOT, "deployments", `${chainId}.json`);
}

const readJson = (p: string): any => JSON.parse(readFileSync(p, "utf8"));
const writeJson = (p: string, v: unknown): void => writeFileSync(p, JSON.stringify(v, null, 2) + "\n", "utf8");

/** Splits the file into its field documentation and its records, which every writer has to put back. */
function readRecords(chainId: bigint | number | string): {
  meta: unknown;
  records: Record<string, Deployment>;
} {
  const { _meta, ...records } = readJson(deploymentsPath(chainId));
  return { meta: _meta, records };
}

function writeRecords(chainId: bigint | number | string, meta: unknown, records: Record<string, Deployment>): void {
  writeJson(deploymentsPath(chainId), { ...(meta ? { _meta: meta } : {}), ...records });
}

/** Contracts this repo deploys, keyed by name. `_meta` is stripped. */
export function loadDeployments(chainId: bigint | number | string): Record<string, Deployment> {
  return readRecords(chainId).records;
}

/**
 * External references plus every deployed address flattened back into `Name` / `Name_impl`.
 *
 * Synchronous on purpose: these are one-shot scripts and tests, there is no concurrent work to
 * hold up, and being sync means the config can also be read at module scope.
 */
export function loadConfig<T = any>(chainId: bigint | number | string): T {
  const external = readJson(configPath(chainId));
  const flat: Record<string, string> = {};
  for (const [name, d] of Object.entries(loadDeployments(chainId))) {
    flat[name] = d.proxy;
    if (d.impl) flat[`${name}_impl`] = d.impl;
    if (d.pendingImpl) flat[`${name}_impl_pending`] = d.pendingImpl;
  }
  return { ...external, ...flat } as T;
}

/**
 * Writes a merged config back, routing each key to the file it belongs to.
 *
 * Records already in deployments keep every field this view cannot see: only the addresses —
 * `proxy`, `impl`, `pendingImpl` — are touched, so a script that reads the merged config and saves
 * it cannot erase build data it never knew about. A pair of new `Name` + `Name_impl` keys is
 * recognised as a new deployment and gets a record with the remaining fields left empty for the
 * deploy scripts to fill.
 */
export function saveConfig(chainId: bigint | number | string, merged: Record<string, unknown>): void {
  const { meta, records } = readRecords(chainId);
  const external: Record<string, unknown> = {};

  const isDeployment = (key: string): boolean =>
    key in records || `${key}_impl` in merged || `${key}_impl_pending` in merged;

  const setAddress = (name: string, field: "proxy" | "impl" | "pendingImpl", value: unknown): void => {
    records[name] = { ...(records[name] ?? blank()), [field]: value as string };
  };

  /** The contract a suffixed key belongs to, or null when the key does not carry that suffix. */
  const nameFor = (key: string, suffix: string): string | null =>
    key.endsWith(suffix) ? key.slice(0, -suffix.length) : null;

  for (const [key, value] of Object.entries(merged)) {
    const pending = nameFor(key, "_impl_pending");
    if (pending && isDeployment(pending)) {
      setAddress(pending, "pendingImpl", value);
      continue;
    }
    const impl = nameFor(key, "_impl");
    if (impl && isDeployment(impl)) {
      setAddress(impl, "impl", value);
      continue;
    }
    if (isDeployment(key)) {
      setAddress(key, "proxy", value);
      continue;
    }
    external[key] = value;
  }

  // A pending implementation missing from the merged view has been resolved or abandoned. Dropping
  // the key here is what makes `delete config[name + "_impl_pending"]` reach the file: the loop
  // above only ever sees keys that are present.
  for (const [name, record] of Object.entries(records)) {
    if (record.pendingImpl && !(`${name}_impl_pending` in merged)) {
      const { pendingImpl, ...rest } = record;
      records[name] = rest;
    }
  }

  writeRecords(chainId, meta, records);
  writeJson(configPath(chainId), external);
}

/**
 * Writes one deployment record — the path a deploy or verify script takes.
 *
 * Distinct from `saveConfig` on purpose. That one serves the many scripts that only know addresses
 * and must not touch fields they never read; this one is for the caller that has just deployed and
 * therefore knows all of them: a new implementation invalidates buildHash, deployedFrom,
 * deployedAt and build at once, and leaving any of them stale would be worse than leaving them
 * empty — the pull-request check reads these fields as claims. Anything omitted from `record` is
 * reset rather than carried over, so a partial write cannot leave a mix of old and new.
 */
export function saveDeployment(
  chainId: bigint | number | string,
  name: string,
  record: Partial<Deployment> & { proxy: string }
): void {
  const { meta, records } = readRecords(chainId);
  records[name] = { ...blank(), ...record };
  writeRecords(chainId, meta, records);
}

function blank(): Deployment {
  return {
    proxy: "",
    impl: null,
    buildHash: null,
    matchesDeployed: false,
    deployedFrom: null,
    deployedAt: null,
    build: null,
  };
}
