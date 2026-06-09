import * as dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-chai-matchers";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-gas-reporter"
import '@typechain/hardhat'
// hardhat-tracer подключать только при тестах/запуске ноды — при compile инициирует провайдер и падает с "missing field _format" (EDR/Hardhat 2.26).
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
                            yul: false
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
            }
        },
        hardhat: {
            gasPrice: 100000000000,
            chainId: process.env.FORK_SEPOLIA === "1" ? 11155111 : 31337,
            hardfork: "cancun",
            // allowUnlimitedContractSize: true,
            forking: process.env.FORK_SEPOLIA === "1"
                ? {
                    enabled: true,
                    url: process.env.ETHEREUM_SEPOLIA_RPC_URL || "https://rpc.sepolia.org",
                    blockNumber: 	10446607,
                    // Не задаём blockNumber — используем latest, иначе RPC может вернуть "historical state is not available" (нужен archive-узел).
                  }
                : {
                    enabled: false,
                    url: process.env.BASE_RPC_URL || '',
                    blockNumber: 42103098,
                  },
        },
        sepolia: {
            chainId: 11155111,
            url: process.env.ETHEREUM_SEPOLIA_RPC_URL,
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_DEV
            }
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
        only: [':Fundraise$', ':RewardSystem$', ':Treasury$', ':Token$', ':ManagerRegistry$', ':Rewards2$', ':Market$', ':Lending8$', ':Oracle$', ':AdaptiveCurveIrm$', ':LimitedSeller$', ':BTC8L$', ':EscrowFactory$', ':AmlEscrow$', ':WelcomeBonus$', ':MaclearBonus$'],
        spacing: 2,
        format: 'json',
    },
    etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY,
        customChains: [
            {
                network: "base",
                chainId: 8453,
                urls: {
                  apiURL: "https://api.basescan.org/api",
                  browserURL: "https://basescan.org"
                }
            },
            {
                network: "base_sepolia",
                chainId: 84532,
                urls: {
                  apiURL: "https://api-sepolia.basescan.org/api",
                  browserURL: "https://sepolia.basescan.org"
                }
              },
            {
                network: "unichain_sepolia",
                chainId: 1301,
                urls: {
                  apiURL: "https://api.etherscan.io/v2/api",
                  browserURL: "https://sepolia.uniscan.xyz"
                }
              }
        ]
    }
};

export default config;
