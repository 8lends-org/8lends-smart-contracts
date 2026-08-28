import hre from "hardhat";

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
export function requireRealNetwork(): void {
  if (!process.env.HARDHAT_NETWORK) {
    throw new Error(
      "No network chosen. Hardhat would fall back to its in-process fork of Base, which claims " +
        "chainId 8453, so this run would print real addresses for a throwaway chain.\n" +
        "  --network base     act for real\n" +
        "  --network sepolia  act on testnet\n" +
        "  --network hardhat  rehearse against the fork"
    );
  }

  if (hre.network.name === "hardhat") {
    console.log("\n" + "=".repeat(72));
    console.log("REHEARSAL on the in-process fork of Base. Addresses come from the Base address");
    console.log("book, execution does not: nothing below reaches a real chain.");
    console.log("=".repeat(72) + "\n");
  }
}
