/**
 * Parse all logs from all project contracts block-by-block.
 * One getLogs request per 1000 blocks, from current block backwards.
 * Decodes each log to eventName and args by key.
 *
 * Usage:
 *   npx hardhat run scripts/test-events.ts --network sepolia
 */

import * as fs from "fs/promises";
import * as path from "path";
import { ethers } from "hardhat";
import { readJsonFile } from "./utils/helpers";
import type { Log } from "ethers";
import { Interface, type InterfaceAbi } from "ethers";

const CHUNK_SIZE = 10000;
const MAX_BLOCKS_COUNT = 200000;

/** Contract address keys in config (proxy or impl names we care about). */
const CONTRACT_KEYS = [
  "Fundraise",
  "RewardSystem",
  "ManagerRegistry",
  "Lending8",
  "Market",
  "Oracle",
  "LimitedSeller",
  "Rewards2",
  "Treasury",
  "TreasuryLending",
  "AdaptiveCurveIrm",
  "token",
] as const;

/** ABI file names for contracts that have events (same order / names as in abi-exporter). */
const ABI_FILES = [
  "Fundraise",
  "RewardSystem",
  "ManagerRegistry",
  "Lending8",
  "Market",
  "Oracle",
  "LimitedSeller",
  "Rewards2",
  "Treasury",
  "Token",
  "AdaptiveCurveIrm",
];

/** Build topic0 (event signature hash) -> Interface for decoding. */
async function buildTopic0Decoders(): Promise<Map<string, Interface>> {
  const topic0ToInterface = new Map<string, Interface>();
  const abisDir = path.resolve(process.cwd(), "abis");

  for (const name of ABI_FILES) {
    const abiPath = path.join(abisDir, `${name}.json`);
    let abi: InterfaceAbi;
    try {
      abi = await readJsonFile(abiPath);
    } catch {
      continue;
    }
    const iface = Interface.from(abi);
    for (const fragment of iface.fragments) {
      if (fragment.type === "event" && "topicHash" in fragment) {
        topic0ToInterface.set((fragment as { topicHash: string }).topicHash, iface);
      }
    }
  }
  return topic0ToInterface;
}

/** Make value JSON-friendly (bigint -> string, nested objects preserved). */
function toSerializable(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(toSerializable);
  if (value && typeof value === "object" && value !== null && typeof (value as object).constructor === "function") {
    const obj = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(obj)) {
      out[k] = toSerializable(v);
    }
    return out;
  }
  return value;
}

/** Decoded args as keyed object with bigint as string. */
function argsToKeyedObject(args: { toObject: (deep?: boolean) => Record<string, unknown> }): Record<string, unknown> {
  const obj = args.toObject(true);
  return toSerializable(obj) as Record<string, unknown>;
}

export interface DecodedEvent {
  blockNumber: number;
  blockIndex: number;
  transactionHash: string;
  address: string;
  eventName: string;
  args: Record<string, unknown>;
}

function decodeLog(log: Log, topic0Decoders: Map<string, Interface>): DecodedEvent | null {
  const topic0 = log.topics[0];
  if (!topic0) return null;
  const iface = topic0Decoders.get(topic0);
  if (!iface) return null;
  try {
    const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
    if (!parsed) return null;
    const args = argsToKeyedObject(parsed.args);
    return {
      blockNumber: log.blockNumber,
      blockIndex: log.index ?? 0,
      transactionHash: log.transactionHash,
      address: log.address,
      eventName: parsed.name,
      args,
    };
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const net = await ethers.provider.getNetwork();
  console.log(`Network: ${net.name} (chainId: ${net.chainId})\n`);

  const configPath = `./scripts/config/${net.chainId}-config.json`;
  let config: Record<string, string> = {};
  try {
    config = await readJsonFile(configPath);
  } catch {
    throw new Error(`Config not found: ${configPath}`);
  }

  const addresses: string[] = [];
  for (const key of CONTRACT_KEYS) {
    const addr = config[key];
    if (addr && typeof addr === "string" && addr.startsWith("0x")) {
      addresses.push(addr);
    }
  }

  const uniqueAddresses = [...new Set(addresses)];
  console.log(`Contracts (${uniqueAddresses.length}): ${uniqueAddresses.join(", ")}\n`);

  const currentBlock = await ethers.provider.getBlockNumber();

  console.log(`Current block: ${currentBlock}`);
  console.log(`Chunk size: ${CHUNK_SIZE} blocks\n`);

  const allLogs: Log[] = [];

  const minBlock = Math.max(0, currentBlock - MAX_BLOCKS_COUNT);
  for (let toBlock = currentBlock; toBlock >= minBlock; toBlock -= CHUNK_SIZE) {
    const fromBlock = Math.max(minBlock, toBlock - CHUNK_SIZE + 1);
    const blocksInChunk = toBlock - fromBlock + 1;

    await new Promise(resolve => setTimeout(resolve, 300));
    try {
      const logs = await ethers.provider.getLogs({
        address: uniqueAddresses,
        fromBlock,
        toBlock,
      });
      for (const log of logs) {
        allLogs.push(log);
      }
      console.log(`Blocks ${fromBlock}–${toBlock} (${blocksInChunk}) found ${logs.length} logs (total: ${allLogs.length})`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      const isRecoverable =
        msg.includes("Unknown block") ||
        (msg.includes("block") && msg.includes("unknown")) ||
        msg.includes("method handler crashed") ||
        msg.includes("crashed") ||
        msg.includes("Request timeout") ||
        msg.includes("free tier");
      if (isRecoverable) {
        console.warn(`Stopping: RPC error for blocks ${fromBlock}–${toBlock} (${msg}). Using ${allLogs.length} logs so far.`);
        break;
      }
      throw err;
    }
  }

  allLogs.sort((a, b) => {
    if (a.blockNumber !== b.blockNumber) return a.blockNumber - b.blockNumber;
    return (a.index ?? 0) - (b.index ?? 0);
  });

  const topic0Decoders = await buildTopic0Decoders();
  const decodedEvents: DecodedEvent[] = [];
  let unknownCount = 0;
  for (const log of allLogs) {
    if(log.removed) continue;
    const decoded = decodeLog(log, topic0Decoders);
    if (decoded) {
      decodedEvents.push(decoded);
    } else {
      unknownCount++;
    }
  }

  console.log(`\nTotal logs: ${allLogs.length} (decoded: ${decodedEvents.length}, unknown topic0: ${unknownCount})`);
  if (allLogs.length > 0) {
    console.log(`First block: ${allLogs[0].blockNumber}, last block: ${allLogs[allLogs.length - 1].blockNumber}\n`);
  }

  const shortHash = (s: string, head = 6, tail = 4) =>
    s.length <= head + tail + 2 ? s : `${s.slice(0, head + 2)}…${s.slice(-tail)}`;
  const compactVal = (v: unknown): string => {
    const s = String(v);
    if (s.startsWith("0x") && s.length > 14) return shortHash(s);
    if (s.length > 12 && !s.startsWith("0x")) return s.slice(0, 11) + "…";
    return s;
  };
  const rows = decodedEvents.map((e) => {
    const base: Record<string, string> = {
      "block:idx": `${e.blockNumber}:${e.blockIndex}`,
      "tx | addr": `${shortHash(e.transactionHash)} | ${shortHash(e.address)}`,
      event: e.eventName,
    };
    for (const [k, v] of Object.entries(e.args)) {
      base[k] = compactVal(v);
    }
    return base;
  });

  const colOrder = ["block:idx", "tx | addr", "event"];
  const argKeys = new Set<string>();
  for (const row of rows) {
    for (const k of Object.keys(row)) {
      if (!colOrder.includes(k)) argKeys.add(k);
    }
  }
  const columns = [...colOrder, ...[...argKeys].sort()];
  const widths = columns.map((c) => Math.max(c.length, ...rows.map((r) => String(r[c] ?? "").length)));
  const pad = (s: string, w: number) => s.padEnd(w);
  const sep = widths.map((w) => "─".repeat(w)).join("─┼─");
  const header = columns.map((c, i) => pad(c, widths[i])).join(" │ ");
  const lines: string[] = [header, sep, ...rows.map((r) => columns.map((c, i) => pad(String(r[c] ?? ""), widths[i])).join(" │ "))];
  const tableText = lines.join("\n");
  const outPath = path.resolve(process.cwd(), "test-events.log");
  await fs.writeFile(outPath, tableText, "utf8");
  console.log(`Table written to ${outPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
