import * as dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-gas-reporter"
import '@typechain/hardhat'
// Only for tests / running a node: on compile it initialises the provider and fails with "missing field _format" (EDR/Hardhat 2.26).
if (!process.argv.includes("compile")) {
    require("hardhat-tracer");
}
import "@nomicfoundation/hardhat-verify";
import "hardhat-abi-exporter";


dotenv.config();

// Base's public endpoint is the default so that `npx hardhat test` works on a fresh clone and in
// CI without any secret. It is rate-limited and slow (minutes rather than seconds on a cold fork
// cache), so set BASE_RPC_URL to a dedicated provider for day-to-day work and for deployments.
const BASE_RPC_URL = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const SEPOLIA_RPC_URL = process.env.ETHEREUM_SEPOLIA_RPC_URL || "https://rpc.sepolia.org";

/**
 * HD accounts for a network, or none at all when the mnemonic is unset. An accounts object
 * without a mnemonic fails config validation with HH8, which is what breaks `hardhat test` in
 * CI — there are no mnemonics there. A network with no accounts loads fine and simply cannot
 * sign, which is the honest outcome for an environment that has no key.
 */
function hdAccounts(mnemonic: string | undefined) {
    if (!mnemonic) return undefined;
    return { mnemonic, initialIndex: Number(process.env.INITIAL_INDEX) || 0 };
}

const config: HardhatUserConfig = {
    solidity: {
        compilers: [
            {
                version: '0.8.23',
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 50,
                        details: {
                            yul: true
                        }
                    },
                },
            }
        ]
    },
    networks: {
        base: {
            chainId: 8453,
            url: BASE_RPC_URL,
            accounts: hdAccounts(process.env.OWNER_MNEMONIC_PROD),
        },
        hardhat: {
            gasPrice: 100000000000,
            chainId: 8453,
            hardfork: "cancun",
            // allowUnlimitedContractSize: true,
            // Always on, no switch: general/oracle/balance-table assert against the real Base
            // deployment. No blockNumber: the public RPC has no archive state.
            forking: {
                enabled: true,
                url: BASE_RPC_URL,
            },
        },
        sepolia: {
            chainId: 11155111,
            url: SEPOLIA_RPC_URL,
            accounts: hdAccounts(process.env.OWNER_MNEMONIC_DEV),
        }
    },
    gasReporter: {
        enabled: true
    },
    abiExporter: {
        path: './abis',
        runOnCompile: true,
        clear: true,
        flat: true,
        only: [':Fundraise$', ':RewardSystem$', ':Treasury$', ':Token$', ':ManagerRegistry$', ':Rewards2$', ':Market$', ':Lending8$', ':Oracle$', ':AdaptiveCurveIrm$', ':LimitedSeller$', ':BTC8L$', ':EscrowFactory$', ':AmlEscrow$', ':WelcomeBonus$', ':MaclearBonus$', ':CustomBonus$', ':LeagueBonus$', ':CryptoCourseBonus$'],
        spacing: 2,
        format: 'json',
    },
    etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY,
    }
};

export default config;
