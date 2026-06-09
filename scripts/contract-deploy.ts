import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { upgrades } from "hardhat";
import * as readline from "readline";
import { readJsonFile, writeJsonFile } from "./helpers";

dotenv.config();

function askConfirm(question: string): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      const normalized = answer.trim().toLowerCase();
      resolve(normalized === "yes" || normalized === "y");
    });
  });
}

type Config = Record<string, string>;

type DeployDescriptor = {
  useProxy: boolean;
  initializer?: string;
  getProxyArgs?: (config: Config, owner: string) => unknown[];
  getConstructorArgs?: (config: Config) => unknown[];
  configKey: string;
  configKeyImpl?: string;
};

const DEPLOY_DESCRIPTORS: Record<string, DeployDescriptor> = {
  WETH: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner, "Test WETH", "WETH", 18],
    configKey: "WETH",
    configKeyImpl: "WETH_impl",
  },
  WBTC: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner, "Test WBTC", "WBTC", 8],
    configKey: "WBTC",
    configKeyImpl: "WBTC_impl",
  },
  USDC: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner, "Test USDC", "USDC", 6],
    configKey: "USDC",
    configKeyImpl: "USDC_impl",
  },
  Treasury: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: () => [],
    configKey: "Treasury",
    configKeyImpl: "Treasury_impl",
  },
  TreasuryLending: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: () => [],
    configKey: "TreasuryLending",
    configKeyImpl: "TreasuryLending_impl",
  },
  Lending8: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner],
    configKey: "Lending8",
    configKeyImpl: "Lending8_impl",
  },
  Oracle: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner],
    configKey: "Oracle",
    configKeyImpl: "Oracle_impl",
  },
  ManagerRegistry: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: () => [],
    configKey: "ManagerRegistry",
    configKeyImpl: "ManagerRegistry_impl",
  },
  Fundraise: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config, _owner) => {
      const trustedSignerKey = process.env.TRUSTED_SIGNER_PRIVATE_KEY;
      if (!trustedSignerKey) throw new Error("TRUSTED_SIGNER_PRIVATE_KEY not set");
      const trustedSigner = new ethers.Wallet(trustedSignerKey, ethers.provider);
      if (!config.Treasury || !config.ManagerRegistry || !config.RewardSystem) {
        throw new Error("Treasury, ManagerRegistry, RewardSystem required in config");
      }
      return [config.Treasury, config.ManagerRegistry, trustedSigner.address, config.RewardSystem];
    },
    configKey: "Fundraise",
    configKeyImpl: "Fundraise_impl",
  },
  RewardSystem: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config) => {
      if (!config.ManagerRegistry || !config.token || !config.USDC || !config.uniswapV2Router) {
        throw new Error("ManagerRegistry, token, USDC, uniswapV2Router required in config");
      }
      return [config.ManagerRegistry, config.token, config.USDC, config.uniswapV2Router];
    },
    configKey: "RewardSystem",
    configKeyImpl: "RewardSystem_impl",
  },
  Rewards2: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config) => {
      if (!config.ManagerRegistry || !config.token || !config.USDC || !config.uniswapV2Router) {
        throw new Error("ManagerRegistry, token, USDC, uniswapV2Router required in config");
      }
      return [config.ManagerRegistry, config.token, config.USDC, config.uniswapV2Router];
    },
    configKey: "Rewards2",
    configKeyImpl: "Rewards2_impl",
  },
  Market: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config) => {
      if (!config.ManagerRegistry) throw new Error("ManagerRegistry required in config");
      return [config.ManagerRegistry];
    },
    configKey: "Market",
    configKeyImpl: "Market_impl",
  },
  LimitedSeller: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config) => {
      if (
        !config.Fundraise ||
        !config.ManagerRegistry ||
        !config.uniswapV2Router ||
        !config.USDC ||
        !config.token
      ) {
        console.log("Fundraise:", config.Fundraise);
        console.log("ManagerRegistry:", config.ManagerRegistry);
        console.log("uniswapV2Router:", config.uniswapV2Router);
        console.log("USDC:", config.USDC);
        console.log("token:", config.token);
        throw new Error(
          "Fundraise, ManagerRegistry, uniswapV2Router, USDC, token required in config"
        );
      }
      const percent = process.env.LIMITED_SELLER_PERCENT ?? "60000"; // 6% in 1e6 basis points
      return [
        config.Fundraise,
        config.uniswapV2Router,
        config.USDC,
        config.token,
        percent,
        config.ManagerRegistry,
      ];
    },
    configKey: "LimitedSeller",
    configKeyImpl: "LimitedSeller_impl",
  },
  Token: {
    useProxy: false,
    getConstructorArgs: () => [],
    configKey: "token",
  },
  AdaptiveCurveIrm: {
    useProxy: false,
    getConstructorArgs: (config) => {
      const lending8 = config.Lending8;
      if (!lending8) throw new Error("Lending8 required in config");
      return [lending8];
    },
    configKey: "AdaptiveCurveIrm",
  },
  MockERC20: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner, "Test usdt", "TUSDT"],
    configKey: "USDC",
    configKeyImpl: "USDC_impl",
  },
  FlashLiquidator: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config, owner) => {
      if (!config.Lending8) throw new Error("Lending8 required in config");
      if (!config.uniswapV2Router) throw new Error("uniswapV2Router required in config");
      return [config.Lending8, owner, config.uniswapV2Router];
    },
    configKey: "FlashLiquidator",
    configKeyImpl: "FlashLiquidator_impl",
  },
  BTC8L: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (_config, owner) => [owner, _config.Lending8],
    configKey: "BTC8L",
    configKeyImpl: "BTC8L_impl",
  },
  AmlEscrow: {
    useProxy: false,
    getConstructorArgs: () => [],
    configKey: "AmlEscrow",
  },
  EscrowFactory: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config) => {
      if (!config.AmlEscrow) throw new Error("AmlEscrow required in config (deploy AmlEscrow first)");
      if (!config.Fundraise) throw new Error("Fundraise required in config");
      if (!config.USDC) throw new Error("USDC required in config");
      const signerAddr = (config as Record<string, string>).escrowSigner || (config as Record<string, string>).trustedSigner;
      if (!signerAddr) throw new Error("escrowSigner or trustedSigner required in config");
      return [config.AmlEscrow, config.Fundraise, config.USDC, signerAddr];
    },
    configKey: "EscrowFactory",
    configKeyImpl: "EscrowFactory_impl",
  },
  MaclearBonus: {
    useProxy: true,
    initializer: "initialize",
    getProxyArgs: (config) => {
      if (!config.ManagerRegistry || !config.USDC) {
        throw new Error("ManagerRegistry, USDC required in config");
      }
      const bonusAmount = process.env.MACLEAR_BONUS_AMOUNT ?? "20000000"; // 20 USDC (6 decimals)
      return [config.ManagerRegistry, config.USDC, bonusAmount];
    },
    configKey: "MaclearBonus",
    configKeyImpl: "MaclearBonus_impl",
  },
};

async function main(): Promise<void> {
  const contractName = process.env.CONTRACT;
  if (!contractName) {
    throw new Error("Set CONTRACT env (e.g. CONTRACT=TreasuryLending)");
  }
  const descriptor = DEPLOY_DESCRIPTORS[contractName];
  if (!descriptor) {
    const known = Object.keys(DEPLOY_DESCRIPTORS).join(", ");
    throw new Error(`Unknown CONTRACT=${contractName}. Known: ${known}`);
  }

  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  const filePath = `./scripts/config/${net.chainId}-config.json`;
  const config = (await readJsonFile(filePath)) as Config;

  const [signer] = await ethers.getSigners();
  const owner = await signer.getAddress();
  console.log("Deploying", contractName, descriptor.useProxy ? "(upgradeable proxy)" : "");
  console.log("Owner:", owner);
  const balance = await ethers.provider.getBalance(owner);
  console.log("Owner native balance:", ethers.formatEther(balance));

  const confirmed = await askConfirm(
    `\nDo you want to deploy ${contractName} to ${net.name} (chainId: ${net.chainId})? (yes/no): `
  );
  if (!confirmed) {
    console.log("Deployment cancelled.");
    return;
  }

  const Factory = await hre.ethers.getContractFactory(contractName);
  let proxyOrContractAddress: string;

  if (descriptor.useProxy) {
    const args = descriptor.getProxyArgs!(config, owner);
    const Proxy = await upgrades.deployProxy(Factory, args, {
      kind: "uups",
      initializer: descriptor.initializer ?? "initialize",
    });
    await Proxy.waitForDeployment();
    proxyOrContractAddress = await Proxy.getAddress();
    console.log(contractName, "(proxy) deployed to:", proxyOrContractAddress);
    (config as Record<string, string>)[descriptor.configKey] = proxyOrContractAddress;
    if (descriptor.configKeyImpl) {
      await new Promise((resolve) => setTimeout(resolve, 12000));
      const implAddress = await upgrades.erc1967.getImplementationAddress(proxyOrContractAddress);
      console.log(contractName, "implementation:", implAddress);
      (config as Record<string, string>)[descriptor.configKeyImpl!] = implAddress;
    }
  } else {
    const args = descriptor.getConstructorArgs!(config);
    const Contract = await Factory.deploy(...args);
    await Contract.waitForDeployment();
    proxyOrContractAddress = await Contract.getAddress();
    console.log(contractName, "deployed to:", proxyOrContractAddress);
    (config as Record<string, string>)[descriptor.configKey] = proxyOrContractAddress;
  }

  if (contractName === "Fundraise") {
    const pk = process.env.TRUSTED_SIGNER_PRIVATE_KEY;
    if (pk) {
      const trustedSigner = new ethers.Wallet(pk, ethers.provider);
      (config as Record<string, string>).trustedSigner = trustedSigner.address;
    }
  }

  await writeJsonFile(filePath, config);
  console.log("Config updated:", descriptor.configKey, "=", proxyOrContractAddress);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});