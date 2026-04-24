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

import { ethers } from "hardhat";

const BASIS_POINTS = 1_000_000n;
const BATCH_SIZE = 200;

/** Fundraise.Stage enum values */
const STAGE_FUNDED = 4;
const STAGE_REPAID = 5;

async function main() {
  const fundraiseAddress = process.env.FUNDRAISE_ADDRESS;
  const limitedSellerAddress = process.env.LIMITED_SELLER_ADDRESS;

  if (!fundraiseAddress || !limitedSellerAddress) {
    throw new Error("Set FUNDRAISE_ADDRESS and LIMITED_SELLER_ADDRESS env vars");
  }

  const fundraise = await ethers.getContractAt("Fundraise", fundraiseAddress);
  const limitedSeller = await ethers.getContractAt("LimitedSeller", limitedSellerAddress);

  const percent = await limitedSeller.percent();
  console.log(`LimitedSeller percent: ${percent} (${Number(percent) / 10000}%)`);

  // Step 1: Get project count and identify Funded/Repaid projects
  const projectCount = Number(await fundraise.projectCount());
  console.log(`Total projects: ${projectCount}`);

  const fundedProjectIds: number[] = [];
  for (let i = 0; i < projectCount; i++) {
    const project = await fundraise.projects(i);
    const stage = Number(project.innerStruct.stage);
    if (stage === STAGE_FUNDED || stage === STAGE_REPAID) {
      fundedProjectIds.push(i);
    }
  }
  console.log(`Funded/Repaid projects: ${fundedProjectIds.length} (${fundedProjectIds.join(", ")})`);

  if (fundedProjectIds.length === 0) {
    console.log("No funded projects — nothing to migrate");
    return;
  }

  // Step 2: Collect unique investor addresses from Invest events
  // We use events only to discover WHO invested, then read current state for HOW MUCH
  console.log("Fetching Invest events to discover investor addresses...");
  const filter = fundraise.filters.Invest();
  const events = await fundraise.queryFilter(filter, 0, "latest");
  console.log(`Found ${events.length} Invest events`);

  // Also collect addresses from InvestmentTransferred events (buyers on secondary market)
  console.log("Fetching InvestmentTransferred events...");
  const transferFilter = fundraise.filters.InvestmentTransferred();
  const transferEvents = await fundraise.queryFilter(transferFilter, 0, "latest");
  console.log(`Found ${transferEvents.length} InvestmentTransferred events`);

  // Collect unique investors per funded project
  const investorsByProject: Map<number, Set<string>> = new Map();

  for (const event of events) {
    const args = (event as any).args;
    const projectId = Number(args.projectId);
    if (!fundedProjectIds.includes(projectId)) continue;

    const investor = args.investor as string;
    if (!investorsByProject.has(projectId)) {
      investorsByProject.set(projectId, new Set());
    }
    investorsByProject.get(projectId)!.add(investor);
  }

  // Add transfer recipients (they may not have Invest events but hold investments)
  for (const event of transferEvents) {
    const args = (event as any).args;
    const projectId = Number(args.projectId);
    if (!fundedProjectIds.includes(projectId)) continue;

    const to = args.to as string;
    if (!investorsByProject.has(projectId)) {
      investorsByProject.set(projectId, new Set());
    }
    investorsByProject.get(projectId)!.add(to);
  }

  // Step 3: Read current on-chain investorInfo and compute earned limits
  // This correctly reflects transfers (transferInvestment zeroes out seller's investedAmount)
  console.log("Reading current on-chain investorInfo for each user×project...");
  const earnedLimits: Map<string, bigint> = new Map();

  for (const pid of fundedProjectIds) {
    const investors = investorsByProject.get(pid);
    if (!investors) continue;

    console.log(`  Project ${pid}: checking ${investors.size} addresses...`);

    for (const investor of investors) {
      const info = await fundraise.investorInfo(investor, pid);
      const currentInvested = info.investedAmount as bigint;

      if (currentInvested > 0n) {
        const delta = (currentInvested * percent) / BASIS_POINTS;
        const existing = earnedLimits.get(investor) || 0n;
        earnedLimits.set(investor, existing + delta);
      }
    }
  }

  console.log(`Users with earned limits: ${earnedLimits.size}`);

  // Step 4: Check which users already have earnedLimitUsdc > 0 (skip them)
  const usersToMigrate: string[] = [];
  const limitsToMigrate: bigint[] = [];

  for (const [user, limit] of earnedLimits) {
    const existing = await limitedSeller.earnedLimitUsdc(user);
    if (existing === 0n) {
      usersToMigrate.push(user);
      limitsToMigrate.push(limit);
    } else {
      console.log(`  Skipping ${user} (already migrated: ${existing})`);
    }
  }

  console.log(`Users to migrate: ${usersToMigrate.length}`);

  if (usersToMigrate.length === 0) {
    console.log("Nothing to migrate");
    return;
  }

  // Step 5: Execute migration in batches
  for (let i = 0; i < usersToMigrate.length; i += BATCH_SIZE) {
    const batchUsers = usersToMigrate.slice(i, i + BATCH_SIZE);
    const batchLimits = limitsToMigrate.slice(i, i + BATCH_SIZE);

    console.log(`Batch ${Math.floor(i / BATCH_SIZE) + 1}: migrating ${batchUsers.length} users...`);

    const tx = await limitedSeller.migrateEarnedLimits(batchUsers, batchLimits);
    const receipt = await tx.wait();
    console.log(`  tx: ${receipt!.hash} (gas: ${receipt!.gasUsed})`);
  }

  console.log("Migration complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
