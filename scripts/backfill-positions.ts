import { Contract } from "ethers";
import { readFileSync } from "fs";
import { ethers } from "hardhat";
import { join } from "path";
import { requireRealNetwork } from "./utils/network-guard";

/**
 * Backfill individual investment positions for existing investors.
 *
 * Reads historical Invest events (chunked by SCAN_BLOCKS), groups by (investor, projectId),
 * checks getPositionCount + investorInfo via Multicall3, then calls backfillPositions().
 *
 * Usage:
 *   npx hardhat run scripts/backfill-positions.ts --network <network>
 *
 * Environment variables:
 *   FUNDRAISE_ADDRESS — address of the Fundraise proxy contract (overrides config)
 */

const SCAN_BLOCKS = 9_000;
const MULTICALL_BATCH = 100;
const RPC_RETRY_MS = 1_000;

const Multicall3Abi = [
  {
    inputs: [
      {
        components: [
          { name: "target", type: "address" },
          { name: "allowFailure", type: "bool" },
          { name: "callData", type: "bytes" },
        ],
        name: "calls",
        type: "tuple[]",
      },
    ],
    name: "aggregate3",
    outputs: [
      {
        components: [
          { name: "success", type: "bool" },
          { name: "returnData", type: "bytes" },
        ],
        name: "returnData",
        type: "tuple[]",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;

async function main() {
  requireRealNetwork();
  const net = await ethers.provider.getNetwork();

  const config: {
    Fundraise: string;
    multicall3: string;
    fundraiseDeployBlock: number;
  } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

  const fundraiseAddress = process.env.FUNDRAISE_ADDRESS ?? config.Fundraise;
  if (!fundraiseAddress) {
    throw new Error("FUNDRAISE_ADDRESS env var or config.Fundraise required");
  }

  const currentBlock =await ethers.provider.getBlockNumber();
  const fromBlock = config.fundraiseDeployBlock;

  const fundraise = await ethers.getContractAt("Fundraise", fundraiseAddress);
  const multicall = new Contract(config.multicall3, Multicall3Abi, ethers.provider);

  // Step 1: collect Invest events in chunks of SCAN_BLOCKS
  console.log(`Scanning Invest events ${fromBlock}…${currentBlock} (chunks of ${SCAN_BLOCKS})...`);

  const groups = new Map<string, { investor: string; projectId: bigint; amounts: bigint[] }>();
  const investFilter = fundraise.filters.Invest();
  let cursor = fromBlock;

  while (cursor <= currentBlock) {
    const endBlock = Math.min(cursor + SCAN_BLOCKS - 1, currentBlock);
    for (;;) {
      console.log(`  getLogs ${cursor}…${endBlock} (left ~${currentBlock - endBlock})`);
      try {
        const events = await fundraise.queryFilter(investFilter, cursor, endBlock);
        for (const event of events) {
          if (!event.args) {
            continue;
          }
          const [projectId, investor, amount] = event.args;
          const key = `${investor as string}-${(projectId as bigint).toString()}`;
          if (!groups.has(key)) {
            groups.set(key, { investor: investor as string, projectId: projectId as bigint, amounts: [] });
          }
          groups.get(key)!.amounts.push(amount as bigint);
        }
        cursor = endBlock + 1;
        break;
      } catch (err: unknown) {
        console.error(`  RPC error, retry in ${RPC_RETRY_MS}ms`, err);
        await new Promise((r) => setTimeout(r, RPC_RETRY_MS));
      }
    }
  }

  const entries = [...groups.entries()];
  console.log(`\nFound ${entries.length} unique (investor, project) pairs`);

  // Step 2: batch-check getPositionCount + investorInfo via Multicall3
  type GroupState = {
    key: string;
    investor: string;
    projectId: bigint;
    amounts: bigint[];
    positionCount: bigint;
    totalClaimed: bigint;
    investedAmount: bigint;
  };

  const states: GroupState[] = [];

  for (let off = 0; off < entries.length; off += MULTICALL_BATCH) {
    const slice = entries.slice(off, off + MULTICALL_BATCH);
    const calls = slice.flatMap(([, { investor, projectId }]) => [
      {
        target: fundraiseAddress,
        allowFailure: false,
        callData: fundraise.interface.encodeFunctionData("getPositionCount", [investor, projectId]),
      },
      {
        target: fundraiseAddress,
        allowFailure: false,
        callData: fundraise.interface.encodeFunctionData("investorInfo", [investor, projectId]),
      },
    ]);
    for (;;) {
      console.log(`  Multicall check batch [${off}…${off + slice.length - 1}]`);
      try {
        const results = await multicall.aggregate3(calls);
        for (let i = 0; i < slice.length; i += 1) {
          const [key, { investor, projectId, amounts }] = slice[i]!;
          const posRow = results[i * 2];
          const infoRow = results[i * 2 + 1];
          if (!posRow.success || !infoRow.success) {
            throw new Error(`multicall failed for ${key}`);
          }
          const [positionCount] = fundraise.interface.decodeFunctionResult("getPositionCount", posRow.returnData);
          const info = fundraise.interface.decodeFunctionResult("investorInfo", infoRow.returnData);
          states.push({
            key,
            investor,
            projectId,
            amounts,
            positionCount: positionCount as bigint,
            totalClaimed: info.totalClaimed as bigint,
            investedAmount: info.investedAmount as bigint,
          });
        }
        break;
      } catch (err: unknown) {
        console.error(`  Multicall error, retry in ${RPC_RETRY_MS}ms`, err);
        await new Promise((r) => setTimeout(r, RPC_RETRY_MS));
      }
    }
  }

  // Step 3: backfill sequentially
  let backfilled = 0;
  let skipped = 0;

  for (const { key, investor, projectId, amounts, positionCount, totalClaimed, investedAmount } of states) {
    if (positionCount > 0n) {
      console.log(`  SKIP ${key}: already has ${positionCount} positions`);
      skipped++;
      continue;
    }
    if (totalClaimed > 0n) {
      console.log(`  SKIP ${key}: totalClaimed > 0, cannot backfill`);
      skipped++;
      continue;
    }
    const sum = amounts.reduce((a, b) => a + b, 0n);
    if (sum !== investedAmount) {
      console.log(`  WARN ${key}: event sum ${sum} != aggregate ${investedAmount}, skipping`);
      skipped++;
      continue;
    }

    console.log(`  Backfilling ${key}: ${amounts.length} positions, total ${ethers.formatUnits(sum, 6)} USDC`);

    for (;;) {
      try {
        const tx = await fundraise.backfillPositions(investor, projectId, amounts);
        await tx.wait();
        backfilled++;
        break;
      } catch (err: unknown) {
        console.error(`  backfillPositions error for ${key}, retry in ${RPC_RETRY_MS}ms`, err);
        await new Promise((r) => setTimeout(r, RPC_RETRY_MS));
      }
    }
  }

  console.log(`\nDone: ${backfilled} backfilled, ${skipped} skipped`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
