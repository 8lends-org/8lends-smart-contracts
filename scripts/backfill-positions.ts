import { ethers } from "hardhat";

/**
 * Backfill individual investment positions for existing investors.
 *
 * Reads historical Invest events, groups by (investor, projectId),
 * and calls backfillPositions() for each group.
 *
 * Usage:
 *   npx hardhat run scripts/backfill-positions.ts --network <network>
 *
 * Environment variables:
 *   FUNDRAISE_ADDRESS — address of the Fundraise proxy contract
 *   FROM_BLOCK — block to start scanning events from (optional, defaults to 0)
 */

async function main() {
  const fundraiseAddress = process.env.FUNDRAISE_ADDRESS;
  if (!fundraiseAddress) {
    throw new Error("FUNDRAISE_ADDRESS env variable required");
  }

  const fromBlock = parseInt(process.env.FROM_BLOCK || "0", 10);

  const fundraise = await ethers.getContractAt("Fundraise", fundraiseAddress);

  console.log(`Scanning Invest events from block ${fromBlock}...`);

  const filter = fundraise.filters.Invest();
  const events = await fundraise.queryFilter(filter, fromBlock);

  console.log(`Found ${events.length} Invest events`);

  // Group by (investor, projectId) => amounts[]
  const groups = new Map<string, { investor: string; projectId: bigint; amounts: bigint[] }>();

  for (const event of events) {
    if (!event.args) continue;
    const [projectId, investor, amount] = event.args;
    const key = `${investor}-${projectId.toString()}`;

    if (!groups.has(key)) {
      groups.set(key, { investor, projectId, amounts: [] });
    }
    groups.get(key)!.amounts.push(amount);
  }

  console.log(`Found ${groups.size} unique (investor, project) pairs`);

  let backfilled = 0;
  let skipped = 0;

  for (const [key, { investor, projectId, amounts }] of groups) {
    // Check if positions already exist (from new invests or prior backfill)
    const existingCount = await fundraise.getPositionCount(investor, projectId);
    if (existingCount > 0n) {
      console.log(`  SKIP ${key}: already has ${existingCount} positions`);
      skipped++;
      continue;
    }

    // Skip investors who have already claimed (contract enforces this too)
    const info = await fundraise.investorInfo(investor, projectId);
    if (info.totalClaimed > 0n) {
      console.log(`  SKIP ${key}: totalClaimed > 0, cannot backfill`);
      skipped++;
      continue;
    }

    // Verify sum matches aggregate
    const sum = amounts.reduce((a, b) => a + b, 0n);
    if (sum !== info.investedAmount) {
      console.log(
        `  WARN ${key}: event sum ${sum} != aggregate ${info.investedAmount}, skipping`
      );
      skipped++;
      continue;
    }

    console.log(
      `  Backfilling ${key}: ${amounts.length} positions, total ${ethers.formatUnits(sum, 6)} USDC`
    );

    const tx = await fundraise.backfillPositions(investor, projectId, amounts);
    await tx.wait();
    backfilled++;
  }

  console.log(`\nDone: ${backfilled} backfilled, ${skipped} skipped`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
