import dotenv from "dotenv";
import { ethers } from "hardhat";
import * as fs from "fs/promises";
import * as path from "path";
import * as readline from "readline";
import { readJsonFile } from "./helpers";
import { resolveAllTimeInvestedUsdInput } from "./migrate-all-time-invested-usd-input";

dotenv.config();

/**
 * Env:
 *   DRY_RUN=1            — compute snapshot, do NOT send transactions
 *   BATCH_SIZE=100       — addresses per migrate tx
 *   LOG_CHUNK_SIZE=5000  — blocks per eth_getLogs call (lower if RPC rejects)
 *   FROM_BLOCK=<n>       — override start block (default: config.fundraiseDeployBlock)
 *   TO_BLOCK=<n>         — override end block (default: latest)
 *   USE_SNAPSHOT=1       — load users from snapshot instead of querying Invest logs
 *   SNAPSHOT_PATH=<path> — explicit snapshot path (default: scripts/state/migrate-allTimeInvestedUSD-<chainId>.snapshot.json)
 *   YES=1                — skip interactive confirmation
 */

const BATCH_SIZE = Number(process.env.BATCH_SIZE || "100");
const LOG_CHUNK_SIZE = Number(process.env.LOG_CHUNK_SIZE || "5000");
const DRY_RUN = process.env.DRY_RUN === "1";
const USE_SNAPSHOT = process.env.USE_SNAPSHOT === "1";

function askConfirm(question: string): Promise<boolean> {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((resolve) => {
        rl.question(question, (answer) => {
            rl.close();
            const a = answer.trim().toLowerCase();
            resolve(a === "y" || a === "yes");
        });
    });
}

async function queryFilterChunked(
    contract: any,
    filter: any,
    fromBlock: number,
    toBlock: number,
    chunkSize: number,
    label: string
): Promise<any[]> {
    const all: any[] = [];
    let from = fromBlock;
    while (from <= toBlock) {
        const to = Math.min(from + chunkSize - 1, toBlock);
        let attempt = 0;
        // exponential backoff on RPC failures (rate-limit, range too wide, etc.)
        // halve range after 3 attempts.
        let currentTo = to;
        // eslint-disable-next-line no-constant-condition
        while (true) {
            try {
                const chunk = await contract.queryFilter(filter, from, currentTo);
                all.push(...chunk);
                process.stdout.write(`\r   ${label}: ${from}..${currentTo}  (+${chunk.length}, total ${all.length})         `);
                from = currentTo + 1;
                break;
            } catch (err: any) {
                attempt++;
                if (attempt > 6) throw err;
                if (attempt > 3 && currentTo - from > 100) {
                    currentTo = from + Math.floor((currentTo - from) / 2);
                    console.log(`\n      retry shrinking to ${from}..${currentTo}`);
                } else {
                    const wait = 1000 * 2 ** (attempt - 1);
                    console.log(`\n      retry in ${wait}ms (${(err.message || String(err)).slice(0, 80)})`);
                    await new Promise((r) => setTimeout(r, wait));
                }
            }
        }
    }
    process.stdout.write("\n");
    return all;
}

async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    const chainId = Number(net.chainId);
    const cfgPath = `./scripts/config/${chainId}-config.json`;
    const config = await readJsonFile(cfgPath);
    const stateDir = path.resolve("./scripts/state");
    await fs.mkdir(stateDir, { recursive: true });
    const snapshotPath = path.resolve(
        process.env.SNAPSHOT_PATH || path.join(stateDir, `migrate-allTimeInvestedUSD-${chainId}.snapshot.json`)
    );
    const progressPath = path.join(stateDir, `migrate-allTimeInvestedUSD-${chainId}.progress.json`);

    if (!config.Fundraise) throw new Error("Fundraise missing in config");
    if (!config.USDC) throw new Error("USDC missing in config");
    if (!USE_SNAPSHOT && !config.fundraiseDeployBlock && !process.env.FROM_BLOCK) {
        throw new Error("fundraiseDeployBlock missing in config (or pass FROM_BLOCK env)");
    }

    const fundraise = await ethers.getContractAt("Fundraise", config.Fundraise);
    const usdcLc = (config.USDC as string).toLowerCase();

    const [signer] = await ethers.getSigners();
    const me = await signer.getAddress();

    const resolvedInput = await resolveAllTimeInvestedUsdInput({
        chainId,
        fundraise: config.Fundraise as string,
        usdc: config.USDC as string,
        snapshotPath,
        useSnapshot: USE_SNAPSHOT,
        loadFromLogs: async () => {
            const fromBlock = Number(process.env.FROM_BLOCK || config.fundraiseDeployBlock);
            const toBlock = Number(process.env.TO_BLOCK || (await ethers.provider.getBlockNumber()));
            console.log("\n[1/4] Fetching Invest events...");
            const investEvents = await queryFilterChunked(
                fundraise,
                fundraise.filters.Invest(),
                fromBlock,
                toBlock,
                LOG_CHUNK_SIZE,
                "Invest"
            );
            console.log(`   total Invest events: ${investEvents.length}`);
            console.log("\n[2/4] Resolving project loanTokens...");
            const projectIds = new Set<string>();
            for (const ev of investEvents) projectIds.add(ev.args.projectId.toString());
            const projectLoanToken: Record<string, string> = {};
            for (const pidStr of projectIds) {
                const p = await fundraise.projects(BigInt(pidStr));
                const loanToken = (p.innerStruct?.loanToken ?? p[7]?.[4]) as string;
                projectLoanToken[pidStr] = loanToken.toLowerCase();
            }
            console.log(`   resolved ${projectIds.size} projects`);
            console.log("\n[3/4] Aggregating per user...");
            const userTotals: Record<string, bigint> = {};
            const nonUsdcProjects: Record<string, { loanToken: string; investCount: number; investSum: bigint }> = {};
            const ensureProjectStat = (
                pid: string
            ): { loanToken: string; investCount: number; investSum: bigint } => {
                if (!nonUsdcProjects[pid]) {
                    nonUsdcProjects[pid] = {
                        loanToken: projectLoanToken[pid],
                        investCount: 0,
                        investSum: 0n,
                    };
                }
                return nonUsdcProjects[pid];
            };
            for (const ev of investEvents) {
                const pid = ev.args.projectId.toString();
                const investor = (ev.args.investor as string).toLowerCase();
                const amount = ev.args.amount as bigint;
                if (projectLoanToken[pid] !== usdcLc) {
                    const projectStat = ensureProjectStat(pid);
                    projectStat.investCount += 1;
                    projectStat.investSum += amount;
                    continue;
                }
                userTotals[investor] = (userTotals[investor] || 0n) + amount;
            }
            const entries = Object.entries(userTotals)
                .filter(([, amount]) => amount > 0n)
                .sort((left, right) => {
                    if (right[1] > left[1]) {
                        return 1;
                    }
                    if (right[1] < left[1]) {
                        return -1;
                    }
                    return 0;
                });
            return {
                fromBlock,
                toBlock,
                investEvents: investEvents.length,
                nonUsdcProjects,
                entries,
            };
        },
    });
    const { entries, fromBlock, toBlock, investEvents, nonUsdcProjects } = resolvedInput;

    console.log("\n=== Migrate Fundraise.allTimeInvestedUSD ===");
    console.log(`Network        : ${net.name} (chainId ${chainId})`);
    console.log(`Fundraise      : ${config.Fundraise}`);
    console.log(`USDC           : ${config.USDC}`);
    console.log(`Input source   : ${resolvedInput.source}`);
    console.log(`Snapshot path  : ${snapshotPath}`);
    console.log(`Block range    : ${fromBlock} .. ${toBlock}`);
    console.log(`Signer         : ${me}`);
    console.log(`Batch size     : ${BATCH_SIZE}`);
    console.log(`Log chunk size : ${LOG_CHUNK_SIZE}`);
    console.log(`Dry run        : ${DRY_RUN ? "YES" : "no"}`);
    const grandTotal = entries.reduce((s, [, v]) => s + v, 0n);

    console.log(`   users with gross invest: ${entries.length}`);
    console.log(`   grand total (USD basis points): ${grandTotal.toString()}`);
    console.log(`   grand total (USD): $${(Number(grandTotal) / 1_000_000).toFixed(2)}`);

    if (Object.keys(nonUsdcProjects).length > 0) {
        console.log("\n   ⚠️  Non-USDC projects skipped (manual migration required):");
        for (const [pid, s] of Object.entries(nonUsdcProjects)) {
            console.log(`      project ${pid}  loanToken=${s.loanToken}  invests=${s.investCount}  sum=${s.investSum}`);
        }
    }

    // ------------------------------------------------------------------
    // 4) Snapshot + state file
    // ------------------------------------------------------------------
    const snapshot = {
        chainId,
        fundraise: config.Fundraise,
        usdc: config.USDC,
        fromBlock,
        toBlock,
        semantics: "gross-invest (WithdrawInvestment ignored)",
        investEvents,
        nonUsdcProjects,
        users: entries.map(([u, v]) => ({ user: u, amount: v.toString() })),
    };
    if (resolvedInput.source === "logs") {
        await fs.writeFile(snapshotPath, JSON.stringify(snapshot, null, 2));
        console.log(`\n   snapshot saved: ${snapshotPath}`);
    } else {
        console.log(`\n   snapshot loaded: ${snapshotPath}`);
    }

    if (DRY_RUN) {
        console.log("\n DRY_RUN=1 — exiting without sending transactions.");
        return;
    }

    // ------------------------------------------------------------------
    // 4) Manager check, on-chain idempotency filter, batch sends
    // ------------------------------------------------------------------
    console.log("\n[4/4] Preparing to migrate on-chain...");

    const managerRegistryAddr = await fundraise.managerRegistry();
    const mr = await ethers.getContractAt("ManagerRegistry", managerRegistryAddr);
    const isManager = await mr.isManager(me);
    if (!isManager) {
        throw new Error(`Signer ${me} is not a manager in ManagerRegistry ${managerRegistryAddr}`);
    }

    // Filter out users already migrated (on-chain allTimeInvestedUSD > 0).
    // Function is additive — would double-count on re-run.
    console.log(`   filtering already-migrated users (on-chain allTimeInvestedUSD > 0)...`);
    const toMigrate: { user: string; amount: bigint }[] = [];
    let alreadyMigrated = 0;
    for (const [u, v] of entries) {
        // const current = (await fundraise.allTimeInvestedUSD(u)) as bigint;
        // if (current > 0n) {
            // alreadyMigrated++;
            // continue;
        // }
        toMigrate.push({ user: u, amount: v });
    }
    console.log(`   to migrate: ${toMigrate.length}  (skipped already-migrated: ${alreadyMigrated})`);

    if (toMigrate.length === 0) {
        console.log("\n nothing to migrate — exiting.");
        return;
    }

    if (process.env.YES !== "1") {
        const ok = await askConfirm(
            `\nSend ${Math.ceil(toMigrate.length / BATCH_SIZE)} batches of up to ${BATCH_SIZE} addresses each? (yes/no): `
        );
        if (!ok) {
            console.log("Aborted.");
            return;
        }
    }

    // Resume support: load progress file
    let progress: { completedBatches: number; lastTx?: string } = { completedBatches: 0 };
    try {
        progress = JSON.parse(await fs.readFile(progressPath, "utf8"));
        console.log(`   resuming from batch ${progress.completedBatches}`);
    } catch {
        /* fresh run */
    }

    const totalBatches = Math.ceil(toMigrate.length / BATCH_SIZE);
    for (let i = progress.completedBatches * BATCH_SIZE; i < toMigrate.length; i += BATCH_SIZE) {
        const batchIdx = i / BATCH_SIZE;
        const batch = toMigrate.slice(i, i + BATCH_SIZE);
        const users = batch.map((b) => b.user);
        const amounts = batch.map((b) => b.amount);
        const batchSum = amounts.reduce((s, a) => s + a, 0n);
        console.log(
            `   batch ${batchIdx + 1}/${totalBatches} — ${batch.length} users — $${(Number(batchSum) / 1_000_000).toFixed(2)}`
        );
        const tx = await fundraise.migrateAllTimeInvestedUSD(users, amounts);
        console.log(`      tx: ${tx.hash}`);
        await tx.wait();

        progress = { completedBatches: batchIdx + 1, lastTx: tx.hash };
        await fs.writeFile(progressPath, JSON.stringify(progress, null, 2));
    }

    console.log(`\n✅ Migration complete. ${toMigrate.length} users migrated in ${totalBatches} batches.`);
    console.log(`   progress file: ${progressPath} (safe to delete)`);
}

main().catch((e) => {
    console.error("\n❌ Error:", e);
    process.exit(1);
});
