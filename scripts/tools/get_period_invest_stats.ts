/**
 * Get Invest events statistics for a specific period
 * 
 * Usage:
 *   npx hardhat run scripts/tools/get_period_invest_stats.ts --network base
 */

import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../utils/helpers";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

interface InvestorStats {
  investor: string;
  totalAmount: bigint;
  transactionCount: number;
}

interface PeriodResults {
  period: {
    start: string;
    end: string;
    startTimestamp: number;
    endTimestamp: number;
  };
  lastScannedBlock: number;
  lastUpdated: string;
  investors: {
    address: string;
    totalAmount: string;
    totalAmountFormatted: string;
    transactionCount: number;
  }[];
  summary: {
    totalInvestors: number;
    totalTransactions: number;
    totalAmount: string;
    totalAmountFormatted: string;
  };
}

async function main(): Promise<void> {
  requireRealNetwork();
  const startDate = new Date("2025-12-02T09:25:00Z");
  const endDate = new Date("2025-12-11T10:00:00Z");
  
  const startTimestamp = Math.floor(startDate.getTime() / 1000);
  const endTimestamp = Math.floor(endDate.getTime() / 1000);

  console.log(`\n📅 Period: ${startDate.toISOString()} - ${endDate.toISOString()}`);
  console.log(`🕐 Timestamps: ${startTimestamp} - ${endTimestamp}\n`);

  const net = await ethers.provider.getNetwork();
  console.log(`Network: ${net.name} (${net.chainId})\n`);

  const config = await readJsonFile(`./scripts/config/${net.chainId}-config.json`);

  const fundraiseAddress = config.Fundraise || config.fundraise;
  if (!fundraiseAddress) {
    throw new Error("Fundraise contract address not found in config");
  }

  console.log(`Fundraise contract: ${fundraiseAddress}\n`);

  const fundraise = await ethers.getContractAt("Fundraise", fundraiseAddress);

  console.log("Fetching Invest events...\n");

  const currentBlock = await ethers.provider.getBlockNumber();
  const deployBlock = config.fundraiseDeployBlock || 0;

  console.log("Estimating block range for the period...");
  
  const AVG_BLOCK_TIME = 2;
  const blocksPerDay = Math.floor(86400 / AVG_BLOCK_TIME);
  const daysInPeriod = Math.ceil((endTimestamp - startTimestamp) / 86400);
  const estimatedBlocksInPeriod = blocksPerDay * (daysInPeriod + 1);
  
  const estimatedStartBlock = Math.max(currentBlock - estimatedBlocksInPeriod, deployBlock);
  
  console.log(`Estimated start block: ${estimatedStartBlock}`);
  console.log(`Current block: ${currentBlock}`);
  console.log(`Blocks to scan: ~${currentBlock - estimatedStartBlock}\n`);

  const filter = fundraise.filters.Invest();
  const CHUNK_SIZE = 10000;
  const outputPath = `./period_invest_stats_${startDate.toISOString().split('T')[0]}_${endDate.toISOString().split('T')[0]}.json`;

  const investorStatsMap = new Map<string, InvestorStats>();
  let totalEvents = 0;
  let eventsOutsidePeriod = 0;
  let resumeBlock = currentBlock;

  try {
    const existingResults: PeriodResults = await readJsonFile(outputPath);
    if (existingResults && existingResults.lastScannedBlock) {
      console.log(`📂 Found existing progress file`);
      console.log(`Last scanned block: ${existingResults.lastScannedBlock}\n`);
      
      resumeBlock = existingResults.lastScannedBlock - 1;
      
      for (const inv of existingResults.investors) {
        investorStatsMap.set(inv.address, {
          investor: inv.address,
          totalAmount: BigInt(inv.totalAmount),
          transactionCount: inv.transactionCount,
        });
      }
      totalEvents = existingResults.summary.totalTransactions;
      console.log(`▶️  Resuming from block ${resumeBlock}\n`);
    }
  } catch (error) {
    console.log(`📝 No existing progress found, starting fresh\n`);
  }

  async function saveProgress(lastScannedBlock: number): Promise<void> {
    const investorStats = Array.from(investorStatsMap.values())
      .sort((a, b) => (b.totalAmount > a.totalAmount ? 1 : -1));

    let grandTotal = BigInt(0);
    for (const stats of investorStats) {
      grandTotal += stats.totalAmount;
    }

    const results: PeriodResults = {
      period: {
        start: startDate.toISOString(),
        end: endDate.toISOString(),
        startTimestamp,
        endTimestamp,
      },
      lastScannedBlock,
      lastUpdated: new Date().toISOString(),
      investors: investorStats.map(stats => ({
        address: stats.investor,
        totalAmount: stats.totalAmount.toString(),
        totalAmountFormatted: `${ethers.formatUnits(stats.totalAmount, 6)} USDC`,
        transactionCount: stats.transactionCount,
      })),
      summary: {
        totalInvestors: investorStats.length,
        totalTransactions: totalEvents,
        totalAmount: grandTotal.toString(),
        totalAmountFormatted: `${ethers.formatUnits(grandTotal, 6)} USDC`,
      },
    };

    await writeJsonFile(outputPath, results);
  }

  for (let toBlock = resumeBlock; toBlock >= estimatedStartBlock; toBlock -= CHUNK_SIZE) {
    const fromBlock = Math.max(toBlock - CHUNK_SIZE + 1, estimatedStartBlock);
    
    await new Promise(resolve => setTimeout(resolve, 500));
    
    console.log(`Scanning blocks ${fromBlock} to ${toBlock}...`);
    
    try {
      const events = await fundraise.queryFilter(filter, fromBlock, toBlock);
      
      let earliestTimestampInChunk = 0;
      
      for (const event of events) {
        const block = await ethers.provider.getBlock(event.blockNumber);
        const timestamp = block?.timestamp || 0;
        
        if (earliestTimestampInChunk === 0 || timestamp < earliestTimestampInChunk) {
          earliestTimestampInChunk = timestamp;
        }

        if (timestamp >= startTimestamp && timestamp <= endTimestamp) {
          const investor = event.args[1] as string;
          const amount = event.args[2] as bigint;

          const existing = investorStatsMap.get(investor) || {
            investor,
            totalAmount: BigInt(0),
            transactionCount: 0,
          };

          existing.totalAmount += amount;
          existing.transactionCount += 1;
          investorStatsMap.set(investor, existing);

          totalEvents++;
        } else if (timestamp < startTimestamp) {
          eventsOutsidePeriod++;
        }
      }

      let timeInfo = "";
      if (earliestTimestampInChunk > 0) {
        const chunkDate = new Date(earliestTimestampInChunk * 1000);
        timeInfo = ` | 📅 ${chunkDate.toISOString().split('T')[0]} ${chunkDate.toISOString().split('T')[1].split('.')[0]}`;
      }
      
      console.log(`  Found ${events.length} events in chunk (${totalEvents} in period, ${eventsOutsidePeriod} before period)${timeInfo}`);
      
      await saveProgress(fromBlock);
      console.log(`  💾 Progress saved to ${outputPath}`);
      
      if (eventsOutsidePeriod > 50) {
        console.log(`  ✂️  Stopping early - found too many events before period start`);
        break;
      }
    } catch (error: any) {
      console.error(`  ❌ Error scanning blocks ${fromBlock}-${toBlock}:`, error.message);
      await saveProgress(toBlock + CHUNK_SIZE);
      console.error(`  💾 Progress saved before error`);
      throw error;
    }
  }

  await saveProgress(estimatedStartBlock);
  
  console.log(`\n✅ Total found ${totalEvents} Invest events in period\n`);

  if (totalEvents === 0) {
    console.log("No Invest events found in the specified period");
    return;
  }

  console.log(`📝 Final results saved to ${outputPath}\n`);

  const finalResults: PeriodResults = await readJsonFile(outputPath);

  console.log("═══════════════════════════════════════════════════════════");
  console.log("           INVESTOR STATISTICS (11-18 Nov 2025)           ");
  console.log("═══════════════════════════════════════════════════════════\n");

  for (const inv of finalResults.investors) {
    console.log(`Investor: ${inv.address}`);
    console.log(`  Transactions: ${inv.transactionCount}`);
    console.log(`  Total Amount: ${inv.totalAmountFormatted}\n`);
  }

  console.log("═══════════════════════════════════════════════════════════");
  console.log("                        SUMMARY                            ");
  console.log("═══════════════════════════════════════════════════════════\n");

  console.log(`Total unique investors: ${finalResults.summary.totalInvestors}`);
  console.log(`Total transactions: ${finalResults.summary.totalTransactions}`);
  console.log(`Total amount: ${finalResults.summary.totalAmountFormatted}\n`);

  console.log("✅ Analysis completed!");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});

