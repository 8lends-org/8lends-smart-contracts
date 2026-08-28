import * as fs from "fs/promises";

type NonUsdcProjectStat = {
    loanToken: string;
    investCount: number;
    investSum: bigint;
};

type MigrationEntry = [user: string, amount: bigint];

type SnapshotUser = {
    user: string;
    amount: string;
};

type SnapshotFile = {
    chainId: number;
    fundraise: string;
    usdc: string;
    fromBlock: number;
    toBlock: number;
    investEvents: number;
    nonUsdcProjects: Record<string, { loanToken: string; investCount: number; investSum: string }>;
    users: SnapshotUser[];
};

type LogInput = {
    fromBlock: number;
    toBlock: number;
    investEvents: number;
    nonUsdcProjects: Record<string, NonUsdcProjectStat>;
    entries: MigrationEntry[];
};

type SnapshotInput = {
    chainId: number;
    fundraise: string;
    usdc: string;
    snapshotPath: string;
};

type ResolveInputParams = {
    chainId: number;
    fundraise: string;
    usdc: string;
    snapshotPath: string;
    useSnapshot: boolean;
    loadFromLogs: () => Promise<LogInput>;
};

type ResolvedInput = {
    fromBlock: number;
    toBlock: number;
    investEvents: number;
    nonUsdcProjects: Record<string, NonUsdcProjectStat>;
    entries: MigrationEntry[];
    snapshotPath: string;
    source: "logs" | "snapshot";
};

function parseSnapshotUsers(users: SnapshotUser[]): MigrationEntry[] {
    return users
        .map((snapshotUser: SnapshotUser): MigrationEntry => {
            return [snapshotUser.user.toLowerCase(), BigInt(snapshotUser.amount)];
        })
        .filter(([, amount]: MigrationEntry) => amount > 0n)
        .sort((left: MigrationEntry, right: MigrationEntry) => {
            if (right[1] > left[1]) {
                return 1;
            }
            if (right[1] < left[1]) {
                return -1;
            }
            return 0;
        });
}

function parseNonUsdcProjects(
    projects: SnapshotFile["nonUsdcProjects"]
): Record<string, NonUsdcProjectStat> {
    return Object.fromEntries(
        Object.entries(projects).map(([projectId, projectStat]) => {
            return [
                projectId,
                {
                    loanToken: projectStat.loanToken.toLowerCase(),
                    investCount: projectStat.investCount,
                    investSum: BigInt(projectStat.investSum),
                },
            ];
        })
    );
}

async function readSnapshotFile(params: SnapshotInput): Promise<ResolvedInput> {
    const snapshotRaw = await fs.readFile(params.snapshotPath, "utf8");
    const snapshot = JSON.parse(snapshotRaw) as SnapshotFile;
    if (snapshot.chainId !== params.chainId) {
        throw new Error(
            `Snapshot chainId mismatch: expected ${params.chainId}, got ${snapshot.chainId}`
        );
    }
    if (snapshot.fundraise.toLowerCase() !== params.fundraise.toLowerCase()) {
        throw new Error(
            `Snapshot Fundraise mismatch: expected ${params.fundraise}, got ${snapshot.fundraise}`
        );
    }
    if (snapshot.usdc.toLowerCase() !== params.usdc.toLowerCase()) {
        throw new Error(`Snapshot USDC mismatch: expected ${params.usdc}, got ${snapshot.usdc}`);
    }
    return {
        fromBlock: snapshot.fromBlock,
        toBlock: snapshot.toBlock,
        investEvents: snapshot.investEvents,
        nonUsdcProjects: parseNonUsdcProjects(snapshot.nonUsdcProjects),
        entries: parseSnapshotUsers(snapshot.users),
        snapshotPath: params.snapshotPath,
        source: "snapshot",
    };
}

/**
 * Resolves migration input either from on-chain logs or from a saved snapshot file.
 */
export async function resolveAllTimeInvestedUsdInput(
    params: ResolveInputParams
): Promise<ResolvedInput> {
    if (params.useSnapshot) {
        return readSnapshotFile({
            chainId: params.chainId,
            fundraise: params.fundraise,
            usdc: params.usdc,
            snapshotPath: params.snapshotPath,
        });
    }
    const logInput = await params.loadFromLogs();
    return {
        fromBlock: logInput.fromBlock,
        toBlock: logInput.toBlock,
        investEvents: logInput.investEvents,
        nonUsdcProjects: logInput.nonUsdcProjects,
        entries: logInput.entries,
        snapshotPath: params.snapshotPath,
        source: "logs",
    };
}
