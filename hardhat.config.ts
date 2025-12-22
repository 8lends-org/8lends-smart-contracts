import * as dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-chai-matchers";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-gas-reporter"
import '@typechain/hardhat'
import "hardhat-tracer";
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
                        runs: 1000,
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
        forked_base: {
            chainId: 8453,
            url: process.env.BASE_RPC_URL || '',
            forking: {
                url: process.env.BASE_RPC_URL || '',
                blockNumber: 35496625,
            },
            accounts: {
                mnemonic: "test test test test test test test test test test test junk",
                count: 10
            }
        },
        hardhat: {
            gasPrice: 100000000000,
            chainId: 31337,
            // allowUnlimitedContractSize: true,
            forking: {
                enabled: true,
                url: process.env.ETHEREUM_RPC_URL || '',
            }
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
        only: [':Fundraise$', ':RewardSystem$', ':Treasury$', ':Token$', ':ManagerRegistry$', ':Rewards2$'],
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
