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
                        runs: 200,
                        details: {
                            yul: false
                        }
                    },
                },
            }
        ]
    },
    networks: {
        ethereum: {
            chainId: 1,
            url: process.env.ETHEREUM_RPC_URL,
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_PROD,
            }
        },
        base: {
            chainId: 8453,
            url: process.env.BASE_RPC_URL,
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_PROD,
            }
        },
        hardhat: {
            gasPrice: 100000000000,
            chainId: 31337,
            hardfork: "cancun",
            // allowUnlimitedContractSize: true,
            forking: {
                enabled: false,
                url: process.env.BASE_RPC_URL || '',
                blockNumber: 42103098,
                // Фиксированный блок: RPC часто даёт -32001 на "latest"; можно переопределить через BASE_FORK_BLOCK
            },
        },
        base_sepolia: {
            chainId: 84532,
            url: process.env.BASE_SEPOLIA_RPC_URL || '',
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_DEV
            }
        },
        unichain_sepolia: {
            chainId: 1301,
            url: process.env.UNICHAIN_SEPOLIA_RPC_URL,
            accounts: {
                mnemonic: process.env.OWNER_MNEMONIC_DEV
            }
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
        only: [':Fundraise$', ':RewardSystem$', ':Treasury$', ':Token$', ':ManagerRegistry$', ':Rewards2$', ':Market$', ':Lending8$', ':Oracle$', ':AdaptiveCurveIrm$'],
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
