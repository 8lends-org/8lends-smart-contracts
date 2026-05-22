import dotenv from "dotenv";
import { ethers } from "hardhat";
import * as fs from "fs/promises";
import * as path from "path";
import * as readline from "readline";
import { readJsonFile } from "./helpers";

dotenv.config();

/**
 * Env:
 *   DRY_RUN=1            — compute snapshot, do NOT send transactions
 *   BATCH_SIZE=100       — addresses per migrate tx
 *   LOG_CHUNK_SIZE=5000  — blocks per eth_getLogs call (lower if RPC rejects)
 *   FROM_BLOCK=<n>       — override start block (default: config.fundraiseDeployBlock)
 *   TO_BLOCK=<n>         — override end block (default: latest)
 *   YES=1                — skip interactive confirmation
 */

const BATCH_SIZE = Number(process.env.BATCH_SIZE || "100");
const LOG_CHUNK_SIZE = Number(process.env.LOG_CHUNK_SIZE || "5000");
const DRY_RUN = process.env.DRY_RUN === "1";

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

    if (!config.Fundraise) throw new Error("Fundraise missing in config");
    if (!config.USDC) throw new Error("USDC missing in config");
    if (!config.fundraiseDeployBlock && !process.env.FROM_BLOCK) {
        throw new Error("fundraiseDeployBlock missing in config (or pass FROM_BLOCK env)");
    }

    const fromBlock = Number(process.env.FROM_BLOCK || config.fundraiseDeployBlock);
    const toBlock = Number(process.env.TO_BLOCK || (await ethers.provider.getBlockNumber()));

    const fundraise = await ethers.getContractAt("Fundraise", config.Fundraise);
    const usdcLc = (config.USDC as string).toLowerCase();

    const [signer] = await ethers.getSigners();
    const me = await signer.getAddress();

    console.log("\n=== Migrate Fundraise.allTimeInvestedUSD ===");
    console.log(`Network        : ${net.name} (chainId ${chainId})`);
    console.log(`Fundraise      : ${config.Fundraise}`);
    console.log(`USDC           : ${config.USDC}`);
    console.log(`Block range    : ${fromBlock} .. ${toBlock}`);
    console.log(`Signer         : ${me}`);
    console.log(`Batch size     : ${BATCH_SIZE}`);
    console.log(`Log chunk size : ${LOG_CHUNK_SIZE}`);
    console.log(`Dry run        : ${DRY_RUN ? "YES" : "no"}`);

    // ------------------------------------------------------------------
    // 1) Fetch events
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // 2) Build per-project loanToken cache
    // ------------------------------------------------------------------
    console.log("\n[2/4] Resolving project loanTokens...");
    const projectIds = new Set<string>();
    for (const ev of investEvents) projectIds.add(ev.args.projectId.toString());

    const projectLoanToken: Record<string, string> = {};
    for (const pidStr of projectIds) {
        const p = await fundraise.projects(BigInt(pidStr));
        // ethers v6 returns struct as tuple-with-named-fields; innerStruct is nested struct
        const loanToken = (p.innerStruct?.loanToken ?? p[7]?.[4]) as string;
        projectLoanToken[pidStr] = loanToken.toLowerCase();
    }
    console.log(`   resolved ${projectIds.size} projects`);

    // ------------------------------------------------------------------
    // 3) Aggregate per user (USDC only; flag non-USDC)
    // ------------------------------------------------------------------
    console.log("\n[3/4] Aggregating per user...");
    const userTotals: Record<string, bigint> = {};
    const nonUsdcProjects: Record<string, { loanToken: string; investCount: number; investSum: bigint }> = {};

    const ensureProjectStat = (pid: string) => {
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
            const s = ensureProjectStat(pid);
            s.investCount += 1;
            s.investSum += amount;
            continue;
        }
        userTotals[investor] = (userTotals[investor] || 0n) + amount;
    }

    const entries = Object.entries(userTotals)
        .filter(([, v]) => v > 0n)
        .sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0));

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
    const stateDir = path.resolve("./scripts/state");
    await fs.mkdir(stateDir, { recursive: true });
    const snapshotPath = path.join(stateDir, `migrate-allTimeInvestedUSD-${chainId}.snapshot.json`);
    const progressPath = path.join(stateDir, `migrate-allTimeInvestedUSD-${chainId}.progress.json`);

    const snapshot = {
        chainId,
        fundraise: config.Fundraise,
        usdc: config.USDC,
        fromBlock,
        toBlock,
        semantics: "gross-invest (WithdrawInvestment ignored)",
        investEvents: investEvents.length,
        nonUsdcProjects,
        users: entries.map(([u, v]) => ({ user: u, amount: v.toString() })),
    };
    await fs.writeFile(snapshotPath, JSON.stringify(snapshot, null, 2));
    console.log(`\n   snapshot: ${snapshotPath}`);

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
        const current = (await fundraise.allTimeInvestedUSD(u)) as bigint;
        if (current > 0n) {
            alreadyMigrated++;
            continue;
        }
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
