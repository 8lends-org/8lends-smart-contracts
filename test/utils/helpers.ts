// File: test/testSetup.ts

import { ethers, upgrades } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  ManagerRegistry,
  Treasury,
  Fundraise,
  TestERC20,
  Token,
  RewardSystem
} from "../../typechain-types";
import { formatEther } from "ethers";

  // Uniswap V2 on Base (Uniswap Labs deployment, chain 8453)
  const UNISWAP_V2_FACTORY = "0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6";
  const UNISWAP_V2_ROUTER = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";

// Interfaces for Uniswap V2
interface IUniswapV2Factory {
  getPair(tokenA: string, tokenB: string): Promise<string>;
  createPair(tokenA: string, tokenB: string): Promise<any>;
}

interface IUniswapV2Router02 {
  factory(): Promise<string>;
  addLiquidity(
    tokenA: string,
    tokenB: string,
    amountADesired: bigint,
    amountBDesired: bigint,
    amountAMin: bigint,
    amountBMin: bigint,
    to: string,
    deadline: number
  ): Promise<any>;
}

export async function deployContracts() {
  const [owner, manager, notManager, borrower, investor, treasuryAdmin, backend, usr1, usr2, usr3, inviter] = await ethers.getSigners();

  // Deploy TestERC20 (upgradeable USDC mock, 6 decimals)
  const TestERC20Factory = await ethers.getContractFactory("TestERC20", owner);
  const usdcToken = await upgrades.deployProxy(TestERC20Factory, [owner.address, "TEST USDC Token", "USDC", 6]) as unknown as TestERC20;

  // Deploy ManagerRegistry
  const ManagerRegistryFactory = await ethers.getContractFactory("ManagerRegistry",owner);
  const managerRegistry = await upgrades.deployProxy(ManagerRegistryFactory, []) as unknown as ManagerRegistry;

  // Deploy Treasury
  const TreasuryFactory = await ethers.getContractFactory("Treasury",owner);
  const treasury = await upgrades.deployProxy(TreasuryFactory, []) as unknown as Treasury;


  const TokenFactory = await ethers.getContractFactory("Token", owner);
  const token = await TokenFactory.deploy() as Token;
  
  // Set ManagerRegistry in Token
  await token.setManagerRegistry(await managerRegistry.getAddress());

  // Deploy RewardSystem
  const RewardSystemFactory = await ethers.getContractFactory("RewardSystem",owner);
  const rewardSystem = await upgrades.deployProxy(RewardSystemFactory, [
    await managerRegistry.getAddress(),
    await token.getAddress(),
    await usdcToken.getAddress(),
    UNISWAP_V2_ROUTER
  ]) as unknown as RewardSystem;




  // Deploy Fundraise
  const FundraiseFactory = await ethers.getContractFactory("Fundraise",owner);
  const fundraise = await upgrades.deployProxy(FundraiseFactory, [
    await treasury.getAddress(),
    await managerRegistry.getAddress(),
    backend.address,
    await rewardSystem.getAddress()
  ]) as unknown as Fundraise;

  // console.warn("::: REWARD SYSTEM", await rewardSystem.getAddress());
  // console.warn("::: MANAGER REGISTRY", await managerRegistry.getAddress());
  // console.warn("::: FUNDRAISE", await fundraise.getAddress());






  // Set up roles and permissions
  await managerRegistry.connect(owner).setManagerStatusBatch([owner.address, manager.address], [true, true]);
  await managerRegistry.connect(owner).setContractAddresses(
    await rewardSystem.getAddress(),
    await fundraise.getAddress(),
    await treasury.getAddress()
  );



  // Create TOKEN1111/USDC pair on Uniswap and add liquidity
  const {router, poolAddress} = await setupUniswapLiquidity(owner, token, usdcToken, managerRegistry);
  
  return {
    owner,
    manager,
    notManager,
    borrower,
    investor,
    treasuryAdmin,
    usdcToken,
    managerRegistry,
    treasury,
    fundraise,
    rewardSystem,
    backend,
    usr1,
    usr2,
    usr3,
    token,
    inviter,
    router,
    poolAddress
  };
}

async function setupUniswapLiquidity(owner: any, token: Token, usdcToken: TestERC20, managerRegistry: ManagerRegistry) {
  console.log("");
  console.log("[🦄 UNISWAP LIQUIDITY ]");
  

  
  // Connect to Uniswap contracts
  const factory = await ethers.getContractAt("contracts/interfaces/IUniswapV2Factory.sol:IUniswapV2Factory", UNISWAP_V2_FACTORY) as any;
  const router = await ethers.getContractAt("contracts/lending/interfaces/IUniswapV2Router02.sol:IUniswapV2Router02", UNISWAP_V2_ROUTER) as any;
  
  // Create TOKEN1111/USDC pair
  const tokenAddress = await token.getAddress();
  const usdtAddress = await usdcToken.getAddress();
  
  console.log("📝 Creating TOKEN1111/USDC pair...");
  await factory.createPair(tokenAddress, usdtAddress);
  
  const pairAddress = await factory.getPair(tokenAddress, usdtAddress);
  console.log("✅ Pair created at:", pairAddress);
  
  // Mint tokens for liquidity price should be 0.01 USDC per TOKEN1111
  const liquidityAmount1111 = ethers.parseEther("1000000"); // 100,000 TOKEN1111
  const liquidityAmountUSDC = ethers.parseUnits("10000", 6); // 1,000 USDC (price = 0.01 USDC per TOKEN1111)


  
  await token.mint(owner.address, liquidityAmount1111);
  await usdcToken.mint(owner.address, liquidityAmountUSDC);
  
  // Approve tokens for router
  await token.connect(owner).approve(UNISWAP_V2_ROUTER, liquidityAmount1111);
  await usdcToken.connect(owner).approve(UNISWAP_V2_ROUTER, liquidityAmountUSDC);
  
  // Add liquidity
  // console.log("💧 Adding liquidity...");
  const deadline = (await time.latest()) + 3600 * 24 * 7; // 7 days

  // calc pool address
  const poolAddress = await factory.getPair(tokenAddress, usdtAddress);
  // console.log("::: POOL ADDRESS", poolAddress);

   
  await managerRegistry.connect(owner).setPoolStatus(poolAddress, true);

  
  await router.connect(owner).addLiquidity(
    tokenAddress,
    usdtAddress,
    liquidityAmount1111,
    liquidityAmountUSDC,
    0, // amountAMin
    0, // amountBMin
    owner.address,
    deadline
  );

  // const poolAddress = await factory.getPair(tokenAddress, usdtAddress);
  //pool balance
  const poolBalance = await token.balanceOf(poolAddress);
  const usdtBalance = await usdcToken.balanceOf(poolAddress);
  // console.log("::: POOL BALANCE", formatEther(poolBalance));
  // console.log("::: USDT BALANCE", formatUnits(usdtBalance, 6));
  
  console.log("✅ Liquidity added successfully!");
  console.log(`💰 Price: `, 100/Number(formatEther((await router.getAmountsOut(ethers.parseUnits("100", 6), [usdtAddress, tokenAddress]))[1])));
  return {router, poolAddress};

  // Update pair address in RewardSystem
}