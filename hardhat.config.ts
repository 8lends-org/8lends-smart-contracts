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
            url: process.env.BASE_RPC_URL,
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_PROD,
                initialIndex: Number(process.env.INITIAL_INDEX) || 0
            },
        },
        hardhat: {
            gasPrice: 100000000000,
            chainId: 8453,
            hardfork: "cancun",
            // allowUnlimitedContractSize: true,
            // Always on, no switch: general/Oracle/balance-table assert against the real base
            // deployment, and the forked network must not depend on an env var — otherwise
            // `npx hardhat test` differs per machine. No blockNumber: the RPC has no archive state.
            forking: {
                enabled: true,
                url: process.env.BASE_RPC_URL || "",
            },
        },
        sepolia: {
            chainId: 11155111,
            url: process.env.ETHEREUM_SEPOLIA_RPC_URL,
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_DEV,
                initialIndex: Number(process.env.INITIAL_INDEX) || 0
            },
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
