import hre from "hardhat";
import { mine } from "@nomicfoundation/hardhat-network-helpers";

/**
 * Refuses to run when no network was chosen. Hardhat then falls back to its in-process network,
 * which forks Base and reports chainId 8453 — so the script resolves the real Base address book
 * while executing on a throwaway chain, and every address and calldata it prints looks genuine.
 *
 * Hardhat passes `--network` through as HARDHAT_NETWORK, so its absence means nobody chose. To
 * rehearse against the fork, choose it: `--network hardhat`. Same execution, but deliberate, and
 * announced so the output cannot be mistaken for a real run.
 *
 * Every script that resolves the address book calls this, readers included: one rule is easier to
 * hold than a per-script judgement about which output could mislead, and the cost is one flag.
 */
export async function requireRealNetwork(): Promise<void> {
  if (!process.env.HARDHAT_NETWORK) {
    throw new Error(
      "No network chosen. Hardhat would fall back to its in-process fork of Base, which claims " +
        "chainId 8453, so this run would print real addresses for a throwaway chain.\n" +
        "  --network base     act for real\n" +
        "  --network sepolia  act on testnet\n" +
        "  --network hardhat  rehearse against the fork"
    );
  }

  if (hre.network.name !== "hardhat") return;

  console.log("\n" + "=".repeat(72));
  console.log("REHEARSAL on the in-process fork of Base. Addresses come from the Base address");
  console.log("book, execution does not: nothing below reaches a real chain.");
  console.log("=".repeat(72) + "\n");

  // Executing *at* the fork block needs to know which hardfork governed it, and Hardhat ships an
  // activation history only for chains it knows by name — 8453 is not one, so any call fails with
  // "No known hardfork for execution on historical block N (relative to fork block number N)".
  // Reads are fine; it is execution that trips. Mining one block moves execution past the fork
  // point, where the configured `hardfork` applies and no history is consulted.
  //
  // Not fixable in config: `hardforkHistory` for 8453 is accepted and lands in the resolved
  // config, but makes no difference under EDR, and pinning blockNumber does not help either —
  // the fork block itself is always the "historical" one.
  await mine();
}
