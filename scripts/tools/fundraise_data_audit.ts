/**
 * Audit how much data is currently stored on the Fundraise contract.
 *
 * Reports:
 *   - projectCount + breakdown by stage
 *   - Total Invest events (proxy for sub-positions count)
 *   - Unique (investor, projectId) pairs (proxy for investorInfo entries)
 *   - Unique investors overall
 *   - Total invested USDC across all projects
 *   - Estimated storage-slot usage
 *   - Estimated data-migration cost if moving to a new contract
 *
 * Read-only: uses direct RPC provider (no wallet/mnemonic needed).
 *
 * Usage:
 *   NETWORK=base   npx ts-node scripts/tools/fundraise_data_audit.ts
 *   NETWORK=sepolia npx ts-node scripts/tools/fundraise_data_audit.ts
 *
 * Env overrides:
 *   FROM_BLOCK=NNN     — start block for event scan (default: config.fundraiseDeployBlock or 0)
 *   CHUNK_SIZE=NNN     — eth_getLogs chunk (default: 9999 for public RPCs)
 */

import * as dotenv from "dotenv";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

// Fundraise Stage enum (see Fundraise.sol)
const STAGE_NAMES = [
  "ComingSoon",
  "Open",
  "PreFunded",
  "Funded",
  "Repaid",
  "Canceled",
];

// Fundraise event topic0 hashes
const TOPIC_INVEST = ethers.id("Invest(uint256,address,uint256)");
const TOPIC_CLAIMED = ethers.id("Claimed(uint256,address,uint256)");
const TOPIC_PROJECT_CREATED = ethers.id("ProjectCreated(uint256,address,uint256)");
const TOPIC_WITHDRAW_INVESTMENT = ethers.id("WithdrawInvestment(uint256,address,uint256)");
const TOPIC_INVESTMENT_TRANSFERRED = ethers.id(
  "InvestmentTransferred(uint256,address,address,uint256,uint256)"
);

// Cost model constants
const GAS_PER_PROJECT_WRITE = 200_000;
const GAS_PER_INVESTORINFO = 45_000;
const GAS_PER_SUBPOSITION = 60_000;
const GAS_PER_NONCE = 22_000;
const GAS_PER_PROJECT_CLAIMED = 22_000;

const NETWORKS: Record<string, { chainId: number; rpcEnv: string }> = {
  base: { chainId: 8453, rpcEnv: "BASE_RPC_URL" },
  sepolia: { chainId: 11155111, rpcEnv: "ETHEREUM_SEPOLIA_RPC_URL" },
};

// Minimal ABI for Fundraise reads
const FUNDRAISE_ABI = [
  "function projectCount() view returns (uint256)",
  "function projects(uint256) view returns (uint256 hardCap, uint256 softCap, uint256 totalInvested, uint256 startAt, uint256 preFundDuration, uint256 investorInterestRate, uint256 openStageEndAt, tuple(uint256 platformInterestRate, uint256 totalRepaid, address borrower, uint256 fundedTime, address loanToken, uint8 stage) innerStruct)",
];

async function withRetry<T>(fn: () => Promise<T>, maxAttempts = 10): Promise<T> {
  let lastErr: any;
  for (let i = 0; i < maxAttempts; i++) {
    try {
      return await fn();
    } catch (e: any) {
      lastErr = e;
      // Extract nested messages from ethers error wrappers
      const innerMsg = (e?.info?.error?.message ?? "").toString().toLowerCase();
      const outerMsg = (e?.message ?? "").toString().toLowerCase();
      const shortMsg = (e?.shortMessage ?? "").toString().toLowerCase();
      const combined = `${innerMsg} ${outerMsg} ${shortMsg}`;
      const isRateLimit =
        combined.includes("rate limit") ||
        combined.includes("too many") ||
        combined.includes("over rate") ||
        combined.includes("missing revert data") ||   // often wraps rate-limit responses
        combined.includes("-32016") ||
        combined.includes("-32005");
      if (isRateLimit) {
        const delayMs = 500 * Math.pow(2, Math.min(i, 6));
        await new Promise((r) => setTimeout(r, delayMs));
        continue;
      }
      throw e;
    }
  }
  throw lastErr;
}

const ETHERSCAN_V2_API = "https://api.etherscan.io/v2/api";

type LogLite = { topics: string[]; data: string; blockNumber: number };

/**
 * Fetch logs via Etherscan V2 API — no per-request block range limit,
 * paginates by 1000-record pages until exhausted. Much faster than RPC eth_getLogs.
 */
async function fetchLogsViaEtherscan(
  chainId: number,
  address: string,
  topic0: string,
  fromBlock: number,
  toBlock: number,
  apiKey: string
): Promise<LogLite[]> {
  const all: LogLite[] = [];
  let page = 1;
  const pageSize = 1000;

  while (true) {
    const params = new URLSearchParams({
      chainid: String(chainId),
      module: "logs",
      action: "getLogs",
      address,
      topic0,
      fromBlock: String(fromBlock),
      toBlock: String(toBlock),
      page: String(page),
      offset: String(pageSize),
      apikey: apiKey,
    });
    const url = `${ETHERSCAN_V2_API}?${params.toString()}`;
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`Etherscan HTTP ${resp.status}: ${await resp.text()}`);
    const json: any = await resp.json();

    if (
      json.status === "0" &&
      (json.message === "No records found" || json.result?.length === 0)
    ) {
      break;
    }
    if (json.status !== "1") {
      throw new Error(
        `Etherscan API error: status=${json.status} message=${json.message} result=${JSON.stringify(json.result).slice(0, 200)}`
      );
    }

    const items = json.result as Array<{
      topics: string[];
      data: string;
      blockNumber: string;
    }>;

    for (const it of items) {
      all.push({
        topics: it.topics,
        data: it.data,
        blockNumber: parseInt(it.blockNumber, 16),
      });
    }

    process.stdout.write(`\r    page ${page} (+${items.length}), total ${all.length}    `);

    if (items.length < pageSize) break;
    page++;
    // Free tier is 5 req/sec — modest pause
    await new Promise((r) => setTimeout(r, 250));
  }
  process.stdout.write("\n");
  return all;
}

async function main() {
  requireRealNetwork();
  const networkName = (process.env.NETWORK ?? "base").toLowerCase();
  const netCfg = NETWORKS[networkName];
  if (!netCfg) {
    throw new Error(`Unknown network: ${networkName}. Use base or sepolia.`);
  }
  const rpcUrl = process.env[netCfg.rpcEnv];
  if (!rpcUrl) {
    throw new Error(`Missing env var: ${netCfg.rpcEnv}`);
  }
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const chainId = netCfg.chainId;

  const configPath = path.join(__dirname, "..", "config", `${chainId}-config.json`);
  const config: any = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const fundraiseAddr: string = config.Fundraise;

  if (!fundraiseAddr) {
    throw new Error(`No Fundraise address in ${configPath}`);
  }

  const tipBlock = await provider.getBlockNumber();
  const fromBlock = Number(process.env.FROM_BLOCK ?? config.fundraiseDeployBlock ?? 0);
  const chunkSize = Number(process.env.CHUNK_SIZE ?? 9999);

  console.log(`\n═══════════════════════════════════════════════════════════`);
  console.log(`  Fundraise Data Audit`);
  console.log(`═══════════════════════════════════════════════════════════`);
  console.log(`  Network:     ${networkName} (chainId=${chainId})`);
  console.log(`  RPC:         ${rpcUrl.replace(/\/[^\/]{20,}$/, "/<hidden>")}`);
  console.log(`  Fundraise:   ${fundraiseAddr}`);
  console.log(`  Scan range:  blocks ${fromBlock} → ${tipBlock}`);
  console.log(`───────────────────────────────────────────────────────────\n`);

  const fundraise = new ethers.Contract(fundraiseAddr, FUNDRAISE_ABI, provider);

  // ── 1. Project count + per-stage breakdown ──
  console.log(`[1/4] Reading projects…`);
  const projectCount = Number(await fundraise.projectCount());
  console.log(`      projectCount = ${projectCount}`);

  const stageBreakdown: Record<string, number> = {};
  let totalInvested = 0n;
  let totalRepaid = 0n;
  for (let pid = 0; pid < projectCount; pid++) {
    if (pid > 0) await new Promise((r) => setTimeout(r, 80));  // throttle for public RPC
    const p = await withRetry(() => fundraise.projects(pid));
    const inner = p.innerStruct;
    const stage = Number(inner.stage);
    const stageName = STAGE_NAMES[stage] ?? `unknown(${stage})`;
    stageBreakdown[stageName] = (stageBreakdown[stageName] ?? 0) + 1;
    totalInvested += BigInt(p.totalInvested);
    totalRepaid += BigInt(inner.totalRepaid);
    if (pid % 50 === 0 && pid > 0) {
      process.stdout.write(`\r      read ${pid}/${projectCount}    `);
    }
  }
  process.stdout.write(`\r      read ${projectCount}/${projectCount}    \n`);
  console.log(`      by stage:`, stageBreakdown);
  console.log(`      totalInvested = ${ethers.formatUnits(totalInvested, 6)} USDC`);
  console.log(`      totalRepaid   = ${ethers.formatUnits(totalRepaid, 6)} USDC\n`);

  // ── 2. Fetch key events via Etherscan V2 API (no block-range limit) ──
  const etherscanKey = process.env.ETHERSCAN_API_KEY;
  if (!etherscanKey) {
    throw new Error("Missing ETHERSCAN_API_KEY — required for fast log scanning");
  }
  console.log(`[2/4] Scanning events via Etherscan V2 API…`);
  console.log(`  Invest events:`);
  const investLogs = await fetchLogsViaEtherscan(chainId, fundraiseAddr, TOPIC_INVEST, fromBlock, tipBlock, etherscanKey);
  console.log(`  Claimed events:`);
  const claimedLogs = await fetchLogsViaEtherscan(chainId, fundraiseAddr, TOPIC_CLAIMED, fromBlock, tipBlock, etherscanKey);
  console.log(`  ProjectCreated events:`);
  const createdLogs = await fetchLogsViaEtherscan(chainId, fundraiseAddr, TOPIC_PROJECT_CREATED, fromBlock, tipBlock, etherscanKey);
  console.log(`  WithdrawInvestment events:`);
  const withdrawLogs = await fetchLogsViaEtherscan(chainId, fundraiseAddr, TOPIC_WITHDRAW_INVESTMENT, fromBlock, tipBlock, etherscanKey);
  console.log(`  InvestmentTransferred events:`);
  const transferLogs = await fetchLogsViaEtherscan(chainId, fundraiseAddr, TOPIC_INVESTMENT_TRANSFERRED, fromBlock, tipBlock, etherscanKey);
  console.log();

  // ── 3. Collect unique investors and pairs ──
  console.log(`[3/4] Aggregating unique investors and pairs…`);
  const uniqueInvestors = new Set<string>();
  const uniquePairs = new Set<string>();

  for (const log of investLogs) {
    const pid = BigInt(log.topics[1]);
    const investor = "0x" + log.data.slice(26, 66).toLowerCase();
    uniqueInvestors.add(investor);
    uniquePairs.add(`${pid}:${investor}`);
  }
  for (const log of transferLogs) {
    const pid = BigInt(log.topics[1]);
    if (log.data.length >= 130) {
      const to = "0x" + log.data.slice(26, 66).toLowerCase();
      const from2 = "0x" + log.data.slice(90, 130).toLowerCase();
      uniqueInvestors.add(to);
      uniquePairs.add(`${pid}:${to}`);
      uniqueInvestors.add(from2);
      uniquePairs.add(`${pid}:${from2}`);
    }
  }
  console.log(`      unique investors:              ${uniqueInvestors.size}`);
  console.log(`      unique (investor, pid) pairs:  ${uniquePairs.size}`);
  console.log();

  // ── 4. Estimate storage and migration cost ──
  console.log(`[4/4] Estimating storage and migration cost…`);
  const slots =
    projectCount * 10 +
    uniquePairs.size * 2 +
    investLogs.length * 2 +
    uniqueInvestors.size * 1 +
    projectCount * 1;
  const approxBytes = slots * 32;

  const gasProjects = projectCount * GAS_PER_PROJECT_WRITE;
  const gasInvestorInfo = uniquePairs.size * GAS_PER_INVESTORINFO;
  const gasSubPositions = investLogs.length * GAS_PER_SUBPOSITION;
  const gasNonces = uniqueInvestors.size * GAS_PER_NONCE;
  const gasProjectClaimed = projectCount * GAS_PER_PROJECT_CLAIMED;
  const totalGas =
    gasProjects + gasInvestorInfo + gasSubPositions + gasNonces + gasProjectClaimed;

  const BLOCK_GAS_LIMIT = 30_000_000;
  const txCountAtLimit = Math.ceil(totalGas / (BLOCK_GAS_LIMIT * 0.8));

  console.log(`      approx storage slots used:  ${slots.toLocaleString()} (~${(approxBytes / 1024).toFixed(1)} KB)`);
  console.log(`      migration gas breakdown:`);
  console.log(`        projects:            ${gasProjects.toLocaleString()}`);
  console.log(`        investorInfo:        ${gasInvestorInfo.toLocaleString()}`);
  console.log(`        sub-positions:       ${gasSubPositions.toLocaleString()}`);
  console.log(`        userNonces:          ${gasNonces.toLocaleString()}`);
  console.log(`        projectTotalClaimed: ${gasProjectClaimed.toLocaleString()}`);
  console.log(`        TOTAL:               ${totalGas.toLocaleString()}`);
  console.log(`      transactions needed at 80% block limit: ~${txCountAtLimit}`);
  console.log();

  const report = {
    network: `${networkName} (chainId ${chainId})`,
    fundraiseAddress: fundraiseAddr,
    scanRange: { from: fromBlock, to: tipBlock },
    projects: {
      total: projectCount,
      byStage: stageBreakdown,
      totalInvestedUsdc: ethers.formatUnits(totalInvested, 6),
      totalRepaidUsdc: ethers.formatUnits(totalRepaid, 6),
    },
    events: {
      invest: investLogs.length,
      claimed: claimedLogs.length,
      projectCreated: createdLogs.length,
      withdraw: withdrawLogs.length,
      positionTransferred: transferLogs.length,
    },
    investors: {
      unique: uniqueInvestors.size,
      uniqueInvestorProjectPairs: uniquePairs.size,
    },
    storageEstimate: {
      slotsUsed: slots,
      approxBytes,
    },
    migrationCostEstimate: {
      projectsGas: gasProjects,
      investorInfoGas: gasInvestorInfo,
      subPositionsGas: gasSubPositions,
      noncesGas: gasNonces,
      projectClaimedGas: gasProjectClaimed,
      totalGas,
      txCountAtBlockLimit: txCountAtLimit,
    },
  };

  console.log(`═══════════════════════════════════════════════════════════`);
  console.log(`  Summary`);
  console.log(`═══════════════════════════════════════════════════════════`);
  console.log(JSON.stringify(report, null, 2));

  const outPath = path.join(__dirname, `fundraise_audit_${chainId}_${Date.now()}.json`);
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`\nReport saved: ${outPath}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
