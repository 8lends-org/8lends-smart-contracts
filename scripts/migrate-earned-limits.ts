/**
 * Migration script: Calculates earnedLimitUsdc for existing users
 * by reading historical Invest events from Fundraise contract,
 * then calls LimitedSeller.migrateEarnedLimits() in batches.
 *
 * Usage:
 *   npx hardhat run scripts/migrate-earned-limits.ts --network <network>
 *
 * Required env vars:
 *   FUNDRAISE_ADDRESS  — Fundraise proxy address
 *   LIMITED_SELLER_ADDRESS — LimitedSeller proxy address
 *   PERCENT — LimitedSeller percent (e.g. 60000 for 6%)
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

  // Step 1: Read all Invest events
  console.log("Fetching Invest events...");
  const filter = fundraise.filters.Invest();
  const events = await fundraise.queryFilter(filter, 0, "latest");
  console.log(`Found ${events.length} Invest events`);

  // Step 2: Aggregate invested amounts per user per project
  const userProjectInvested: Map<string, Map<number, bigint>> = new Map();

  for (const event of events) {
    const args = (event as any).args;
    const projectId = Number(args.projectId);
    const investor = args.investor as string;
    const amount = args.amount as bigint;

    if (!userProjectInvested.has(investor)) {
      userProjectInvested.set(investor, new Map());
    }
    const projectMap = userProjectInvested.get(investor)!;
    projectMap.set(projectId, (projectMap.get(projectId) || 0n) + amount);
  }

  console.log(`Unique investors: ${userProjectInvested.size}`);

  // Step 3: Filter to only Funded/Repaid projects and compute earnedLimitUsdc
  const projectCount = await fundraise.projectCount();
  const projectStages: Map<number, number> = new Map();

  for (let i = 0; i < Number(projectCount); i++) {
    const project = await fundraise.projects(i);
    const stage = Number(project.innerStruct.stage);
    projectStages.set(i, stage);
  }

  const earnedLimits: Map<string, bigint> = new Map();

  for (const [user, projectMap] of userProjectInvested) {
    let totalPrimaryInvested = 0n;

    for (const [pid, invested] of projectMap) {
      const stage = projectStages.get(pid);
      if (stage === STAGE_FUNDED || stage === STAGE_REPAID) {
        totalPrimaryInvested += invested;
      }
    }

    if (totalPrimaryInvested > 0n) {
      const limit = (totalPrimaryInvested * percent) / BASIS_POINTS;
      earnedLimits.set(user, limit);
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
