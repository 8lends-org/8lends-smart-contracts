import dotenv from "dotenv";
import { ethers } from "hardhat";

dotenv.config();

/**
 * Check ownership/roles of a contract.
 *
 * Supports:
 * - Ownable / OwnableUpgradeable — reads owner()
 * - AccessControl / AccessControlUpgradeable — reconstructs role holders from
 *   RoleGranted / RoleRevoked events (works even when contract does not extend
 *   AccessControlEnumerable, e.g. BTC8L, TestERC20)
 * - Gnosis Safe multisig detection (getThreshold, getOwners)
 * - UUPS proxy implementation address (ERC1967 slot)
 * - Sanity check that the target has code at all
 *
 * Usage:
 *   npx hardhat run scripts/tools/check_owner.ts --network sepolia
 *
 * Optional env:
 *   TARGET=0x...        target address (default: hardcoded below)
 *   FROM_BLOCK=NNN      start block for event scan (default: 0). For very old contracts
 *                       on limited RPCs, set this to speed up the scan.
 *   ETHERSCAN_API_KEY   used for Etherscan V2 logs API (bypasses RPC block-range limits
 *                       like Alchemy free tier's 10-block cap). Highly recommended.
 */

const DEFAULT_TARGET = "0x9FAA2f27401A94410dC88af1aa61038BF6313AC7";

// ERC1967 implementation storage slot: keccak256("eip1967.proxy.implementation") - 1
const ERC1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

// Well-known role hashes for readable output. Extend this map as project needs.
const KNOWN_ROLES: Record<string, string> = {
  [ethers.ZeroHash]: "DEFAULT_ADMIN_ROLE",
  [ethers.id("MINTER_ROLE")]: "MINTER_ROLE",
  [ethers.id("UPGRADER_ROLE")]: "UPGRADER_ROLE",
  [ethers.id("BURNER_ROLE")]: "BURNER_ROLE",
  [ethers.id("PAUSER_ROLE")]: "PAUSER_ROLE",
  [ethers.id("ADMIN_ROLE")]: "ADMIN_ROLE",
  [ethers.id("MANAGER_ROLE")]: "MANAGER_ROLE",
  [ethers.id("OPERATOR_ROLE")]: "OPERATOR_ROLE",
};

function roleName(roleHash: string): string {
  return (
    KNOWN_ROLES[roleHash] ??
    KNOWN_ROLES[roleHash.toLowerCase()] ??
    `unknown role (${roleHash.slice(0, 10)}…)`
  );
}

async function classifyAddress(
  addr: string
): Promise<{ type: string; isSafe: boolean; safeInfo?: string }> {
  const code = await ethers.provider.getCode(addr);
  if (code === "0x" || code === "0x0") {
    return { type: "EOA (regular wallet)", isSafe: false };
  }

  // Try Gnosis Safe interface
  const safeAbi = [
    "function getThreshold() view returns (uint256)",
    "function getOwners() view returns (address[])",
  ];
  const safeCandidate = new ethers.Contract(addr, safeAbi, ethers.provider);
  try {
    const threshold: bigint = await safeCandidate.getThreshold();
    const signers: string[] = await safeCandidate.getOwners();
    return {
      type: `Gnosis Safe (${threshold.toString()}-of-${signers.length})`,
      isSafe: true,
      safeInfo: signers.map((s) => `         - ${s}`).join("\n"),
    };
  } catch {
    return {
      type: `Contract (bytecode ${(code.length - 2) / 2} bytes)`,
      isSafe: false,
    };
  }
}

async function tryOwnable(targetChecksum: string): Promise<void> {
  const ownableAbi = ["function owner() view returns (address)"];
  const contract = new ethers.Contract(targetChecksum, ownableAbi, ethers.provider);

  let owner: string;
  try {
    owner = await contract.owner();
  } catch {
    console.log("\n⚠️  owner() is not implemented — contract is not Ownable-based.");
    console.log("   Skipping to AccessControl check below.");
    return;
  }

  if (owner === ethers.ZeroAddress) {
    console.log("\n👤 Ownable: owner() returned 0x0 — ownership renounced (permanently owner-less).");
    return;
  }

  console.log(`\n👤 Ownable owner: ${owner}`);
  const info = await classifyAddress(owner);
  console.log(`   Type: ${info.type}`);
  if (info.isSafe && info.safeInfo) {
    console.log(`      Signers:`);
    console.log(info.safeInfo);
  }
}

// Etherscan V2 unified API endpoint (works for all supported chains via chainid param)
const ETHERSCAN_V2_API = "https://api.etherscan.io/v2/api";

// Topic hashes for AccessControl events
const TOPIC_ROLE_GRANTED = ethers.id("RoleGranted(bytes32,address,address)");
const TOPIC_ROLE_REVOKED = ethers.id("RoleRevoked(bytes32,address,address)");

type LogEntry = {
  topics: string[];
  blockNumber: number;
  transactionIndex: number;
  logIndex: number;
};

/**
 * Fetch logs via Etherscan V2 API. No block-range limit like RPC has (Alchemy free
 * tier caps eth_getLogs at 10 blocks — unusable for full history). Etherscan returns
 * up to 1000 records per page; paginates until fully consumed.
 */
async function fetchLogsEtherscan(
  chainId: number,
  address: string,
  topic0: string,
  fromBlock: number,
  toBlock: number | "latest",
  apiKey: string
): Promise<LogEntry[]> {
  const all: LogEntry[] = [];
  let page = 1;
  const pageSize = 1000;

  while (true) {
    const params = new URLSearchParams({
      chainid: String(chainId),
      module: "logs",
      action: "getLogs",
      address,
      topic0,
      fromBlock: String(fromBlock),
      toBlock: String(toBlock),
      page: String(page),
      offset: String(pageSize),
      apikey: apiKey,
    });
    const url = `${ETHERSCAN_V2_API}?${params.toString()}`;
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`Etherscan HTTP ${resp.status}: ${await resp.text()}`);
    const json: any = await resp.json();

    // Etherscan returns { status: "0", message: "No records found", result: [] } for empty result
    if (json.status === "0" && (json.message === "No records found" || json.result?.length === 0)) {
      break;
    }
    if (json.status !== "1") {
      // Some other error condition
      throw new Error(`Etherscan API error: status=${json.status} message=${json.message} result=${JSON.stringify(json.result)}`);
    }

    const items = json.result as Array<{
      topics: string[];
      blockNumber: string;
      transactionIndex: string;
      logIndex: string;
    }>;

    for (const it of items) {
      all.push({
        topics: it.topics,
        blockNumber: Number(it.blockNumber),
        transactionIndex: Number(it.transactionIndex),
        logIndex: Number(it.logIndex),
      });
    }

    if (items.length < pageSize) break;
    page++;
    // Etherscan free tier: 5 req/sec — pause to be polite
    await new Promise((r) => setTimeout(r, 250));
  }

  return all;
}

/**
 * Fallback: query events via RPC. Used only if Etherscan API key not set.
 * Very slow on RPCs with tight block-range limits — will warn user.
 */
async function fetchLogsRpc(
  targetChecksum: string,
  topic0: string,
  fromBlock: number
): Promise<LogEntry[]> {
  const filter = { address: targetChecksum, topics: [topic0], fromBlock, toBlock: "latest" as const };
  const logs = await ethers.provider.getLogs(filter);
  return logs.map((l) => ({
    topics: l.topics as string[],
    blockNumber: l.blockNumber,
    transactionIndex: l.transactionIndex,
    logIndex: l.index,
  }));
}

async function tryAccessControl(targetChecksum: string, chainId: number): Promise<void> {
  console.log("\n🔐 AccessControl check (scanning RoleGranted / RoleRevoked events)…");

  const fromBlock = process.env.FROM_BLOCK ? Number(process.env.FROM_BLOCK) : 0;
  const apiKey = process.env.ETHERSCAN_API_KEY;

  let grants: LogEntry[] = [];
  let revokes: LogEntry[] = [];

  if (apiKey) {
    console.log(`   Using Etherscan V2 API (chainId=${chainId}, from block ${fromBlock})`);
    try {
      grants = await fetchLogsEtherscan(chainId, targetChecksum, TOPIC_ROLE_GRANTED, fromBlock, "latest", apiKey);
      revokes = await fetchLogsEtherscan(chainId, targetChecksum, TOPIC_ROLE_REVOKED, fromBlock, "latest", apiKey);
    } catch (err) {
      console.error(`   ⚠️  Etherscan API failed: ${(err as Error).message}`);
      console.error(`   Falling back to RPC (may be slow or fail on limited providers)…`);
      grants = await fetchLogsRpc(targetChecksum, TOPIC_ROLE_GRANTED, fromBlock);
      revokes = await fetchLogsRpc(targetChecksum, TOPIC_ROLE_REVOKED, fromBlock);
    }
  } else {
    console.log(`   ETHERSCAN_API_KEY not set. Using direct RPC (slow on Alchemy free tier / Infura).`);
    grants = await fetchLogsRpc(targetChecksum, TOPIC_ROLE_GRANTED, fromBlock);
    revokes = await fetchLogsRpc(targetChecksum, TOPIC_ROLE_REVOKED, fromBlock);
  }

  if (grants.length === 0 && revokes.length === 0) {
    console.log("   ⓘ No AccessControl events found — either not AccessControl-based, or no roles ever granted.");
    return;
  }

  console.log(`   Found ${grants.length} RoleGranted + ${revokes.length} RoleRevoked events.`);

  // Merge and sort chronologically to correctly apply grant/revoke sequence
  type Ev = {
    role: string;
    account: string;
    kind: "grant" | "revoke";
    blockNumber: number;
    transactionIndex: number;
    logIndex: number;
  };
  // Both events have same layout: topic[0]=event_sig, topic[1]=role, topic[2]=account (both indexed)
  const decode = (e: LogEntry, kind: "grant" | "revoke") => ({
    role: e.topics[1],
    account: "0x" + e.topics[2].slice(-40).toLowerCase(),
    kind,
    blockNumber: e.blockNumber,
    transactionIndex: e.transactionIndex,
    logIndex: e.logIndex,
  });
  const events: Ev[] = [
    ...grants.map((e) => decode(e, "grant")),
    ...revokes.map((e) => decode(e, "revoke")),
  ];
  events.sort(
    (a, b) =>
      a.blockNumber - b.blockNumber ||
      a.transactionIndex - b.transactionIndex ||
      a.logIndex - b.logIndex
  );

  // Replay events to reconstruct current holders per role
  const roleHolders: Map<string, Set<string>> = new Map();
  for (const e of events) {
    if (!roleHolders.has(e.role)) roleHolders.set(e.role, new Set());
    if (e.kind === "grant") roleHolders.get(e.role)!.add(e.account);
    else roleHolders.get(e.role)!.delete(e.account);
  }

  console.log(
    `\n   Current role holders (${roleHolders.size} distinct role${roleHolders.size === 1 ? "" : "s"}):`
  );
  for (const [role, holders] of roleHolders.entries()) {
    const name = roleName(role);
    console.log(`\n   • ${name}`);
    console.log(`     hash: ${role}`);
    if (holders.size === 0) {
      console.log(`     (no active holders — all revoked)`);
      continue;
    }
    for (const holder of holders) {
      const holderChecksum = ethers.getAddress(holder);
      const info = await classifyAddress(holderChecksum);
      console.log(`     - ${holderChecksum}  [${info.type}]`);
      if (info.isSafe && info.safeInfo) {
        console.log(`       Safe signers:`);
        console.log(info.safeInfo);
      }
    }
  }
}

async function main() {
  const target = (process.env.TARGET ?? DEFAULT_TARGET).trim();
  const targetChecksum = ethers.getAddress(target);

  const net = await ethers.provider.getNetwork();

  // Address derived from the mnemonic + accountId configured in hardhat.config.ts
  // for the currently selected network (--network <name>). This is the address
  // hardhat would use to sign transactions when running admin scripts.
  let signerAddress = "(unavailable — no accounts configured for this network)";
  try {
    const signers = await ethers.getSigners();
    if (signers.length > 0) signerAddress = await signers[0].getAddress();
  } catch {
    // network config doesn't provide accounts (e.g. read-only rpc) — leave placeholder
  }

  console.log("=".repeat(72));
  console.log(`Network:  ${net.name} (chainId: ${net.chainId})`);
  console.log(`Signer:   ${signerAddress}`);
  console.log(`Target:   ${targetChecksum}`);
  console.log("=".repeat(72));

  // 1. Sanity check: target has code
  const code = await ethers.provider.getCode(targetChecksum);
  if (code === "0x" || code === "0x0") {
    console.error(
      "\n❌ Target address has NO code — it is either an EOA or the contract does not exist on this network."
    );
    process.exit(1);
  }
  console.log(`\n✅ Target has bytecode (length ${(code.length - 2) / 2} bytes)`);

  // 2. Try Ownable pattern
  await tryOwnable(targetChecksum);

  // 3. Try AccessControl pattern (independent of Ownable — some contracts use both)
  await tryAccessControl(targetChecksum, Number(net.chainId));

  // 4. UUPS proxy implementation slot
  const implSlotRaw = await ethers.provider.getStorage(targetChecksum, ERC1967_IMPL_SLOT);
  const implFromSlot = "0x" + implSlotRaw.slice(-40);
  if (implFromSlot !== ethers.ZeroAddress.toLowerCase()) {
    console.log(`\n📦 UUPS proxy detected. Implementation: ${ethers.getAddress(implFromSlot)}`);
  } else {
    console.log("\n📦 Not a UUPS proxy (or implementation slot empty).");
  }

  console.log("\n" + "=".repeat(72));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
