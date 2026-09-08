import { readFileSync, writeFileSync } from "fs";
import { join } from "path";

/**
 * The single place where a network config path is built.
 *
 * Resolved from this file, not from the process working directory: the previous inline
 * `./scripts/config/${chainId}-config.json` only worked when a script was started from the
 * repository root, and failed silently anywhere else.
 */
export function configPath(chainId: bigint | number | string): string {
  return join(__dirname, "..", "config", `${chainId}-config.json`);
}

/**
 * Reads the config for a network. The shape is per-caller, hence the type parameter.
 *
 * Synchronous on purpose. These are one-shot scripts and tests: there is no concurrent work to
 * hold up, the file is a few kilobytes, and being sync means the config can also be read at module
 * scope — which the async version could not do.
 */
export function loadConfig<T = any>(chainId: bigint | number | string): T {
  return JSON.parse(readFileSync(configPath(chainId), "utf8")) as T;
}

/** Writes the config back. Same formatting as before: 2-space JSON, no trailing newline. */
export function saveConfig(chainId: bigint | number | string, config: unknown): void {
  writeFileSync(configPath(chainId), JSON.stringify(config, null, 2), "utf8");
}
