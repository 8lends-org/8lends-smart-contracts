import { expect } from "chai";
import * as fs from "fs/promises";
import * as os from "os";
import * as path from "path";
import { resolveAllTimeInvestedUsdInput } from "../../scripts/utils/migrate-all-time-invested-usd-input";

// TODO: 
describe("resolveAllTimeInvestedUsdInput", function () {
    it("loads users from snapshot without querying logs", async function () {
        const tempDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "all-time-invested-usd-"));
        const snapshotPath = path.join(tempDirectory, "snapshot.json");
        await fs.writeFile(
            snapshotPath,
            JSON.stringify(
                {
                    chainId: 8453,
                    fundraise: "0xf435A133D6cDCb81061F18a4763560f9931DB57D",
                    usdc: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
                    fromBlock: 100,
                    toBlock: 200,
                    investEvents: 3,
                    nonUsdcProjects: {
                        "7": {
                            loanToken: "0xABCDEFabcdefABCDEFabcdefABCDEFabcdefABCD",
                            investCount: 2,
                            investSum: "42",
                        },
                    },
                    users: [
                        {
                            user: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                            amount: "5000000",
                        },
                        {
                            user: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                            amount: "1000000",
                        },
                    ],
                },
                null,
                2
            )
        );
        let loadFromLogsCalls = 0;

        const actual = await resolveAllTimeInvestedUsdInput({
            chainId: 8453,
            fundraise: "0xf435A133D6cDCb81061F18a4763560f9931DB57D",
            usdc: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
            snapshotPath,
            useSnapshot: true,
            loadFromLogs: async () => {
                loadFromLogsCalls += 1;
                throw new Error("loadFromLogs must not be called");
            },
        });

        expect(loadFromLogsCalls).to.equal(0);
        expect(actual.source).to.equal("snapshot");
        expect(actual.fromBlock).to.equal(100);
        expect(actual.toBlock).to.equal(200);
        expect(actual.investEvents).to.equal(3);
        expect(actual.entries).to.deep.equal([
            ["0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 5000000n],
            ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1000000n],
        ]);
        expect(actual.nonUsdcProjects["7"]).to.deep.equal({
            loanToken: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            investCount: 2,
            investSum: 42n,
        });

        await fs.rm(tempDirectory, { recursive: true, force: true });
    });

    it("delegates to log loader when snapshot mode is disabled", async function () {
        const expected = {
            fromBlock: 1,
            toBlock: 2,
            investEvents: 4,
            nonUsdcProjects: {},
            entries: [["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 15n]] as [string, bigint][],
        };
        let loadFromLogsCalls = 0;

        const actual = await resolveAllTimeInvestedUsdInput({
            chainId: 8453,
            fundraise: "0xf435A133D6cDCb81061F18a4763560f9931DB57D",
            usdc: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
            snapshotPath: "/tmp/unused.json",
            useSnapshot: false,
            loadFromLogs: async () => {
                loadFromLogsCalls += 1;
                return expected;
            },
        });

        expect(loadFromLogsCalls).to.equal(1);
        expect(actual.source).to.equal("logs");
        expect(actual.entries).to.deep.equal(expected.entries);
        expect(actual.investEvents).to.equal(expected.investEvents);
    });
});
