/**
 * Migration script: Calculates earnedLimitUsdc for existing users
 * by reading current on-chain investorInfo state (not historical events),
 * then calls LimitedSeller.migrateEarnedLimits() in batches.
 *
 * Uses on-chain state instead of events to correctly account for
 * investment transfers via Market (transferInvestment zeroes out seller's investedAmount).
 *
 * Usage:
 *   npx hardhat run scripts/migrate-earned-limits.ts --network <network>
 *
 * Required env vars:
 *   FUNDRAISE_ADDRESS  — Fundraise proxy address
 *   LIMITED_SELLER_ADDRESS — LimitedSeller proxy address
 */

export const Multicall3Abi = [
  {
    inputs: [
      {
        components: [
          { name: 'target', type: 'address' },
          { name: 'allowFailure', type: 'bool' },
          { name: 'callData', type: 'bytes' },
        ],
        name: 'calls',
        type: 'tuple[]',
      },
    ],
    name: 'aggregate3',
    outputs: [
      {
        components: [
          { name: 'success', type: 'bool' },
          { name: 'returnData', type: 'bytes' },
        ],
        name: 'returnData',
        type: 'tuple[]',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
] as const;



import { Contract } from "ethers";
import { readFileSync, writeFileSync } from "fs";
import { ethers } from "hardhat";
import { join } from "path";
import { requireOwner } from "./utils/owner-guard";
import { requireRealNetwork } from "./utils/network-guard";

const BASIS_POINTS = 1_000_000n;
const BATCH_SIZE = 200;
/** investorInfo for many addresses in a single Multicall3 aggregate3. */
const INVESTOR_INFO_MULTICALL_BATCH = 100;
/** Delay before retrying after an RPC error. */
const RPC_RETRY_MS = 1000;
/** eth_getLogs: the free tier rejects "ranges over 10000 blocks", so keep the chunk strictly below the limit. */
const SCAN_BLOCKS_PER_QUERY = 10_000;

/** Fundraise.Stage enum values */
const STAGE_FUNDED = 4;
const STAGE_REPAID = 5;
const DELAY = 1000;

async function main() {
  requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log("network: ", net.name);

  const config: {
    Fundraise: string;
    LimitedSeller: string;
    fundraiseDeployBlock: number;
    multicall3: string;
  } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

  if (!config.Fundraise || !config.LimitedSeller) {
    throw new Error("❌ Fundraise or LimitedSeller is not set in the config");
  }

  const fundraise = await ethers.getContractAt("Fundraise", config.Fundraise);
  const limitedSeller = await ethers.getContractAt("LimitedSeller", config.LimitedSeller);
  await requireOwner(config.LimitedSeller, "LimitedSeller");
  const multicall = new Contract(config.multicall3, Multicall3Abi, ethers.provider);

  const percent = await limitedSeller.percent();
  console.log(`LimitedSeller percent: ${percent} (${Number(percent) / 10000}%)`);

  // Step 1: Get project count and identify Funded/Repaid projects
  const projectCount = Number(await fundraise.projectCount());
  console.log(`Total projects: ${projectCount}`);


  async function getFundedProjectIds(): Promise<number[]> {
    const calls: { target: string; allowFailure: boolean; callData: string }[] = [];
    for (let i = 0; i < projectCount; i++) {
      calls.push({
        target: config.Fundraise,
        allowFailure: false,
        callData: fundraise.interface.encodeFunctionData("projects", [i]),
      });
    }
    const results = await multicall.aggregate3(calls);
    const fundedProjectIds: number[] = [];
    for (let i = 0; i < projectCount; i++) {
      const row = results[i];
      if (!row.success) {
        throw new Error(`multicall projects(${i}) failed`);
      }
      const project = fundraise.interface.decodeFunctionResult("projects", row.returnData);
      const stage = Number(project.innerStruct.stage);
      if (stage === STAGE_FUNDED || stage === STAGE_REPAID) {
        fundedProjectIds.push(i);
      }
    }
    return fundedProjectIds;
  }

  const fundedProjectIds: number[] = await getFundedProjectIds();

  console.log(
    `Funded/Repaid projects: ${fundedProjectIds.length} (${fundedProjectIds.join(", ")})`
  );

  if (fundedProjectIds.length === 0) {
    console.log("No funded projects — nothing to migrate");
    return;
  }

  const deployBlock = config.fundraiseDeployBlock;
  const currentBlock = await ethers.provider.getBlockNumber();


  const investTopic = fundraise.interface.getEvent("Invest").topicHash;
  const transferTopic = fundraise.interface.getEvent("InvestmentTransferred").topicHash;
  const fundraiseAddress = await fundraise.getAddress();

  // Step 2: Collect investor addresses from Invest + InvestmentTransferred in one eth_getLogs call per chunk
  // topics[0] = [hashA, hashB] → OR-match: both events in one request
  console.log("Fetching Invest & InvestmentTransferred events (combined)...");
  const investorsByProject: Map<number, Set<string>> = new Map();
  let investCount = 0;
  let transferCount = 0;

  function addInvestor(projectId: number, address: string): void {
    if (!investorsByProject.has(projectId)) {
      investorsByProject.set(projectId, new Set());
    }
    investorsByProject.get(projectId)!.add(address);
  }

  let cursor = deployBlock;
  while (cursor <= currentBlock) {
    const endBlock = Math.min(cursor + SCAN_BLOCKS_PER_QUERY - 1, currentBlock);
    for (;;) {
      console.log(`Querying blocks ${cursor}…${endBlock} (left ~${currentBlock - endBlock})`);
      try {
        const logs = await ethers.provider.getLogs({
          address: fundraiseAddress,
          topics: [[investTopic, transferTopic]],
          fromBlock: cursor,
          toBlock: endBlock,
        });
        for (const log of logs) {
          const parsed = fundraise.interface.parseLog(log);
          if (!parsed) {
            continue;
          }
          const projectId = Number(parsed.args.projectId);
          if (!fundedProjectIds.includes(projectId)) {
            continue;
          }
          if (log.topics[0] === investTopic) {
            addInvestor(projectId, parsed.args.investor as string);
            investCount += 1;
          } else {
            addInvestor(projectId, parsed.args.to as string);
            transferCount += 1;
          }
        }
        cursor = endBlock + 1;
        break;
      } catch (err: unknown) {
        console.error(`RPC error blocks ${cursor}…${endBlock}, retry in ${RPC_RETRY_MS}ms`, err);
        await new Promise((resolve) => setTimeout(resolve, RPC_RETRY_MS));
      }
    }
  }

  console.log(`Found ${investCount} Invest + ${transferCount} InvestmentTransferred events`);

  // Step 3: Read current on-chain investorInfo and compute earned limits
  // This correctly reflects transfers (transferInvestment zeroes out seller's investedAmount)
  console.log("Reading current on-chain investorInfo for each user×project...");
  const earnedLimits: Map<string, bigint> = new Map();

  async function fetchInvestorInfoBatch(
    pid: number,
    investorsSlice: readonly string[]
  ): Promise<readonly { readonly investor: string; readonly investedAmount: bigint }[]> {
    const calls = investorsSlice.map((investor) => ({
      target: config.Fundraise,
      allowFailure: false,
      callData: fundraise.interface.encodeFunctionData("investorInfo", [investor, pid]),
    }));
    for (;;) {
      try {
        const results = await multicall.aggregate3(calls);
        return investorsSlice.map((investor, idx) => {
          const row = results[idx];
          if (!row.success) {
            throw new Error(`investorInfo failed for ${investor}`);
          }
          const info = fundraise.interface.decodeFunctionResult("investorInfo", row.returnData);
          return { investor, investedAmount: info.investedAmount as bigint };
        });
      } catch (err: unknown) {
        console.error(
          `Project ${pid}: RPC error on investorInfo batch (n=${investorsSlice.length}), retry in ${RPC_RETRY_MS}ms`,
          err
        );
        await new Promise((resolve) => setTimeout(resolve, RPC_RETRY_MS));
      }
    }
  }

  for (const pid of fundedProjectIds) {
    const investors = investorsByProject.get(pid);
    if (investors === undefined || investors.size === 0) {
      continue;
    }
    const addresses = [...investors];
    console.log(`  Project ${pid}: checking ${addresses.length} addresses (multicall3 ${INVESTOR_INFO_MULTICALL_BATCH}/batch)...`);
    for (let off = 0; off < addresses.length; off += INVESTOR_INFO_MULTICALL_BATCH) {
      const slice = addresses.slice(off, off + INVESTOR_INFO_MULTICALL_BATCH);
      const rows = await fetchInvestorInfoBatch(pid, slice);
      console.log(off, "/", addresses.length, "rows", rows.length);
      for (const { investor, investedAmount } of rows) {
        if (investedAmount > 0n) {
          const delta = (investedAmount * percent) / BASIS_POINTS;
          const existing = earnedLimits.get(investor) ?? 0n;
          earnedLimits.set(investor, existing + delta);
        }
      }
    }
  }

  console.log(`Users with earned limits: ${earnedLimits.size}`);

  // Step 4: Check which users already have earnedLimitUsdc > 0 (skip them), via multicall3
  const usersToMigrate: string[] = [];
  const limitsToMigrate: bigint[] = [];

  const earnedLimitEntries = [...earnedLimits.entries()];
  console.log(`Checking ${earnedLimitEntries.length} users for existing earnedLimitUsdc (multicall3 ${INVESTOR_INFO_MULTICALL_BATCH}/batch)...`);

  for (let off = 0; off < earnedLimitEntries.length; off += INVESTOR_INFO_MULTICALL_BATCH) {
    const slice = earnedLimitEntries.slice(off, off + INVESTOR_INFO_MULTICALL_BATCH);
    const calls = slice.map(([user]) => ({
      target: config.LimitedSeller,
      allowFailure: false,
      callData: limitedSeller.interface.encodeFunctionData("earnedLimitUsdc", [user]),
    }));
    for (;;) {
      try {
        const results = await multicall.aggregate3(calls);
        for (let i = 0; i < slice.length; i += 1) {
          const [user, limit] = slice[i]!;
          const row = results[i];
          if (!row.success) {
            throw new Error(`earnedLimitUsdc failed for ${user}`);
          }
          const [existing] = limitedSeller.interface.decodeFunctionResult("earnedLimitUsdc", row.returnData);
          if ((existing as bigint) === 0n) {
            usersToMigrate.push(user);
            limitsToMigrate.push(limit);
          } else {
            console.log(`  Skipping ${user} (already migrated: ${existing as bigint})`);
          }
        }
        break;
      } catch (err: unknown) {
        console.error(`earnedLimitUsdc batch [${off}…${off + slice.length - 1}]: error, retry in ${RPC_RETRY_MS}ms`, err);
        await new Promise((resolve) => setTimeout(resolve, RPC_RETRY_MS));
      }
    }
  }

  console.log(`Users to migrate: ${usersToMigrate.length}`);

  if (usersToMigrate.length === 0) {
    console.log("Nothing to migrate");
    return;
  }

  // Step 5: Execute migration in batches
  for (let i = 0; i < usersToMigrate.length; i += BATCH_SIZE) {
    const batchNum = Math.floor(i / BATCH_SIZE) + 1;
    const batchUsers = usersToMigrate.slice(i, i + BATCH_SIZE);
    const batchLimits = limitsToMigrate.slice(i, i + BATCH_SIZE);
    for (;;) {
      console.log(`Batch ${batchNum}: migrating ${batchUsers.length} users...`);
      try {

          console.log("batchUsers", batchUsers);
          console.log("batchLimits", batchLimits);

        const tx = await limitedSeller.migrateEarnedLimits(batchUsers, batchLimits);
        const receipt = await tx.wait();
        console.log(`  tx: ${receipt!.hash} (gas: ${receipt!.gasUsed})`);
        break;
      } catch (err: unknown) {
        console.error(`Batch ${batchNum}: error, retry in ${RPC_RETRY_MS}ms`, err);
        await new Promise((resolve) => setTimeout(resolve, RPC_RETRY_MS));
      }
    }
  }

  console.log("Migration complete!");
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
