/**
 * Parse all Invest events from Fundraise contract
 * 
 * Usage:
 *   npx hardhat run scripts/tools/parse_invest_events.ts --network base
 *   npx hardhat run scripts/tools/parse_invest_events.ts --network sepolia
 * 
 * Optional: Add fundraiseDeployBlock to config to speed up scanning
 */

import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../utils/helpers";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

interface InvestEvent {
  projectId: bigint;
  investor: string;
  amount: bigint;
  blockNumber: number;
  transactionHash: string;
  timestamp: number;
}

interface MonthlyStats {
  month: string;
  transactionCount: number;
  totalAmount: string;
  totalAmountFormatted: string;
  uniqueProjects: number;
}

interface AllTimeStats {
  transactionCount: number;
  totalAmount: string;
  totalAmountFormatted: string;
  uniqueProjects: number;
}

interface ParseResults {
  lastUpdated: string;
  lastScannedBlock: number;
  monthlyStats: MonthlyStats[];
  allTime: AllTimeStats;
  allProjectIds: string[];
  monthlyProjectIds: Record<string, string[]>;
}

async function main(): Promise<void> {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log(`\nNetwork name: ${net.name}\n`);

  const config = await readJsonFile(`./scripts/config/${net.chainId}-config.json`);

  const fundraiseAddress = config.Fundraise || config.fundraise;
  if (!fundraiseAddress) {
    throw new Error("Fundraise contract address not found in config");
  }

  console.log(`Fundraise contract address: ${fundraiseAddress}\n`);

  const fundraise = await ethers.getContractAt("Fundraise", fundraiseAddress);

  console.log("Fetching all Invest events...\n");

  const currentBlock = await ethers.provider.getBlockNumber();
  const deployBlock = config.fundraiseDeployBlock || 0;
  const outputPath = "./parse_invest_events.json";
  
  let existingResults: ParseResults | null = null;
  let startBlock = currentBlock;
  const allEvents: InvestEvent[] = [];

  try {
    existingResults = await readJsonFile(outputPath);
    if (existingResults && existingResults.lastScannedBlock) {
      console.log(`📂 Found existing progress file`);
      console.log(`Last scanned block: ${existingResults.lastScannedBlock}\n`);
      
      if (existingResults.lastScannedBlock > deployBlock) {
        startBlock = existingResults.lastScannedBlock - 1;
        console.log(`▶️  Resuming from block ${startBlock}\n`);
      }
    }
  } catch (error) {
    console.log(`📝 No existing progress found, starting fresh\n`);
  }
  
  console.log(`Current block: ${currentBlock}`);
  console.log(`Deploy block: ${deployBlock}`);
  console.log(`Scanning from block: ${startBlock}`);
  console.log(`Total blocks to scan: ${startBlock - deployBlock}\n`);

  const filter = fundraise.filters.Invest();
  const CHUNK_SIZE = 10000;

  async function updateLastScannedBlock(lastScannedBlock: number): Promise<void> {
    try {
      const existingData: ParseResults = await readJsonFile(outputPath);
      existingData.lastScannedBlock = lastScannedBlock;
      existingData.lastUpdated = new Date().toISOString();
      await writeJsonFile(outputPath, existingData);
    } catch (error) {
      // No file, nothing to do
    }
  }

  async function updateJsonResults(newEvents: InvestEvent[], lastScannedBlock: number): Promise<void> {
    const monthlyStatsMap = new Map<string, { count: number; amount: bigint; projects: Set<string> }>();
    const allUniqueProjects = new Set<string>();
    const monthlyProjectIds: Record<string, Set<string>> = {};
    
    let existingData: ParseResults | null = null;
    try {
      existingData = await readJsonFile(outputPath);
      
      if (existingData && existingData.monthlyStats) {
        for (const monthStat of existingData.monthlyStats) {
          const existingMonthProjects = existingData.monthlyProjectIds?.[monthStat.month] || [];
          monthlyStatsMap.set(monthStat.month, {
            count: monthStat.transactionCount,
            amount: BigInt(monthStat.totalAmount),
            projects: new Set<string>(existingMonthProjects),
          });
          monthlyProjectIds[monthStat.month] = new Set<string>(existingMonthProjects);
        }
      }
      
      if (existingData && existingData.allProjectIds) {
        for (const projectId of existingData.allProjectIds) {
          allUniqueProjects.add(projectId);
        }
      }
    } catch (error) {
      // No file, start from scratch
    }

    for (const event of newEvents) {
      const date = new Date(event.timestamp * 1000);
      const monthKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
      const projectId = event.projectId.toString();

      const existing = monthlyStatsMap.get(monthKey) || { count: 0, amount: BigInt(0), projects: new Set<string>() };
      existing.count += 1;
      existing.amount += event.amount;
      existing.projects.add(projectId);
      monthlyStatsMap.set(monthKey, existing);

      if (!monthlyProjectIds[monthKey]) {
        monthlyProjectIds[monthKey] = new Set<string>();
      }
      monthlyProjectIds[monthKey].add(projectId);

      allUniqueProjects.add(projectId);
    }

    const monthlyStats: MonthlyStats[] = Array.from(monthlyStatsMap.entries())
      .sort((a, b) => b[0].localeCompare(a[0]))
      .map(([month, stats]) => ({
        month,
        transactionCount: stats.count,
        totalAmount: stats.amount.toString(),
        totalAmountFormatted: `${ethers.formatUnits(stats.amount, 6)} USDC`,
        uniqueProjects: stats.projects.size,
      }));

    const totalTransactions = monthlyStats.reduce((sum, stat) => sum + stat.transactionCount, 0);
    const totalAmount = monthlyStats.reduce((sum, stat) => sum + BigInt(stat.totalAmount), BigInt(0));

    const monthlyProjectIdsRecord: Record<string, string[]> = {};
    for (const [month, projects] of Object.entries(monthlyProjectIds)) {
      monthlyProjectIdsRecord[month] = Array.from(projects);
    }

    const results: ParseResults = {
      lastUpdated: new Date().toISOString(),
      lastScannedBlock,
      monthlyStats,
      allTime: {
        transactionCount: totalTransactions,
        totalAmount: totalAmount.toString(),
        totalAmountFormatted: `${ethers.formatUnits(totalAmount, 6)} USDC`,
        uniqueProjects: allUniqueProjects.size,
      },
      allProjectIds: Array.from(allUniqueProjects),
      monthlyProjectIds: monthlyProjectIdsRecord,
    };

    await writeJsonFile(outputPath, results);
  }

  const MAX_RETRIES = 5;
  
  for (let toBlock = startBlock; toBlock >= deployBlock; toBlock -= CHUNK_SIZE) {
    const fromBlock = Math.max(toBlock - CHUNK_SIZE + 1, deployBlock);
    let retryCount = 0;
    let success = false;
    
    while (!success && retryCount < MAX_RETRIES) {
      if (retryCount > 0) {
        const waitTime = 1000 * Math.pow(2, retryCount);
        console.log(`  Retry ${retryCount}/${MAX_RETRIES}, waiting ${waitTime}ms...`);
        await new Promise(resolve => setTimeout(resolve, waitTime));
      } else {
        await new Promise(resolve => setTimeout(resolve, 500));
      }
      
      console.log(`Scanning blocks ${fromBlock} to ${toBlock}..., left ${fromBlock - deployBlock} blocks to scan`);
      
      try {
        const events = await fundraise.queryFilter(filter, fromBlock, toBlock);
        
        const newEvents: InvestEvent[] = [];
        for (const event of events) {
          const projectId = event.args[0];
          const investor = event.args[1];
          const amount = event.args[2];

          const block = await ethers.provider.getBlock(event.blockNumber);
          const timestamp = block?.timestamp || 0;

          const investEvent: InvestEvent = {
            projectId,
            investor,
            amount,
            blockNumber: event.blockNumber,
            transactionHash: event.transactionHash,
            timestamp,
          };

          allEvents.push(investEvent);
          newEvents.push(investEvent);
        }

        console.log(`  Found ${events.length} events in this chunk, total: ${allEvents.length}`);
        
        if (newEvents.length > 0) {
          await updateJsonResults(newEvents, fromBlock);
          console.log(`  Updated ${outputPath} with ${newEvents.length} new events`);
        } else {
          await updateLastScannedBlock(fromBlock);
          console.log(`  No new events, updated lastScannedBlock only`);
        }
        
        success = true;
      } catch (error: any) {
        retryCount++;
        console.error(`  ❌ Error scanning blocks ${fromBlock}-${toBlock}:`, error.message);
        
        if (retryCount >= MAX_RETRIES) {
          console.error(`  ⛔ Max retries reached for blocks ${fromBlock}-${toBlock}. Stopping execution.`);
          console.error(`  💾 Progress saved up to block ${fromBlock + CHUNK_SIZE}`);
          throw new Error(`Failed to scan blocks ${fromBlock}-${toBlock} after ${MAX_RETRIES} attempts`);
        }
      }
    }
  }

  console.log(`\nTotal found ${allEvents.length} Invest events\n`);

  if (allEvents.length === 0) {
    console.log("No Invest events found");
    return;
  }

  console.log(`📝 Final results saved to ${outputPath}\n`);

  const finalResults = await readJsonFile(outputPath);

  console.log("═══════════════════════════════════════════════════════════");
  console.log("                    MONTHLY STATISTICS                     ");
  console.log("═══════════════════════════════════════════════════════════\n");

  for (const monthStat of finalResults.monthlyStats) {
    console.log(`Month: ${monthStat.month}`);
    console.log(`  Transactions: ${monthStat.transactionCount}`);
    console.log(`  Unique Projects: ${monthStat.uniqueProjects}`);
    console.log(`  Total Amount: ${monthStat.totalAmountFormatted}\n`);
  }

  console.log("───────────────────────────────────────────────────────────");
  console.log("                    DETAILED EVENTS                        ");
  console.log("───────────────────────────────────────────────────────────\n");

  for (const event of allEvents) {
    console.log(`Project ID: ${event.projectId}`);
    console.log(`Investor: ${event.investor}`);
    console.log(`Amount: ${ethers.formatUnits(event.amount, 6)} USDC`);
    console.log(`Block: ${event.blockNumber}`);
    console.log(`Transaction: ${event.transactionHash}`);
    console.log("---\n");
  }

  let totalAmount = BigInt(0);
  for (const event of allEvents) {
    totalAmount += event.amount;
  }

  const uniqueProjects = new Set(allEvents.map(e => e.projectId.toString())).size;

  console.log("═══════════════════════════════════════════════════════════");
  console.log("                    INVEST EVENTS SUMMARY                  ");
  console.log("═══════════════════════════════════════════════════════════\n");

  console.log(`Total events: ${allEvents.length}`);
  console.log(`Unique projects: ${uniqueProjects}`);
  console.log(`Total amount (raw): ${totalAmount.toString()}`);
  console.log(`Total amount (formatted): ${ethers.formatUnits(totalAmount, 6)} USDC\n`);

  console.log("✅ Parsing completed!");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});

