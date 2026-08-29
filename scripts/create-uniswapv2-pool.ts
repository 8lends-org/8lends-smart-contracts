import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "./utils/helpers";
import { requireOwner } from "./utils/owner-guard";
import { requireRealNetwork } from "./utils/network-guard";
dotenv.config();

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  const USDC_AMOUNT = process.env.USDC_AMOUNT;
  const TOKEN_AMOUNT = process.env.TOKEN_AMOUNT;

  if (!USDC_AMOUNT || !TOKEN_AMOUNT) {
    throw new Error("USDC_AMOUNT and TOKEN_AMOUNT must be set in env");
  }

  console.log("\nCreating Uniswap pool for Token/USDC");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // Check for required addresses in config
  if (!config.token) {
    throw new Error("Token address not found in config");
  }
  if (!config.USDC) {
    throw new Error("USDC address not found in config");
  }
  if (!config.ManagerRegistry) {
    throw new Error("ManagerRegistry address not found in config");
  }
  if (!config.uniswapV2Router) {
    throw new Error("uniswapV2Router address not found in config");
  }
  if (!config.uniswapV2Factory) {
    throw new Error("uniswapV2Factory address not found in config");
  }

  console.log("Token address:", config.token);
  console.log("USDC address:", config.USDC);
  console.log("Router", config.uniswapV2Router);
  console.log("Factory", config.uniswapV2Factory);

  // Connect to Uniswap contracts
  const factory = await ethers.getContractAt(
    "contracts/interfaces/external/IUniswapV2Factory.sol:IUniswapV2Factory",
    config.uniswapV2Factory
  );
  const router = await ethers.getContractAt(
    "contracts/interfaces/external/IUniswapV2Router02.sol:IUniswapV2Router02",
    config.uniswapV2Router
  );

  // Connect to tokens
  const token = await ethers.getContractAt("Token", config.token);
  const usdcToken = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.USDC);

  // Connect to ManagerRegistry
  const managerRegistry = await ethers.getContractAt("ManagerRegistry", config.ManagerRegistry);
  await requireOwner(config.ManagerRegistry, "ManagerRegistry");
  await requireOwner(config.token, "Token"); // minted below

  console.log("🦄 Setting up Uniswap liquidity...");

  // Check if pair already exists
  const existingPair = await factory.getPair(config.token, config.USDC);
  if (existingPair !== "0x0000000000000000000000000000000000000000") {
    console.log("⚠️  Pair already exists at:", existingPair);
    config.pool = existingPair;
    await writeJsonFile(filePath, config);
    //    return;
  } else {
    // Create TOKEN/USDC pair
    console.log("📝 Creating Token/USDC pair...");
    const createPairTx = await factory.createPair(config.token, config.USDC);
    await createPairTx.wait(5);
  }

  const pairAddress = await factory.getPair(config.token, config.USDC);
  console.log("✅ Pair created at:", pairAddress);
  if (pairAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("Pair not created");
  }

  // Add pool to whitelist for token buying
  console.log("🔒 Adding pool to whitelist for token buying...");
  const setWhitelistTx = await managerRegistry.setPoolStatus(pairAddress, true);
  console.log("tx hash:", setWhitelistTx.hash);
  await setWhitelistTx.wait(5);

  // Mint tokens for liquidity (price = 0.1 USDC per Token)
  const liquidityAmountToken = ethers.parseEther(TOKEN_AMOUNT); // 100,000 Token
  const liquidityAmountUSDC = ethers.parseUnits(USDC_AMOUNT, 6); // 10,000 USDC

  console.log("💰 Minting tokens for liquidity...");

  const balanceToken = await token.balanceOf(signer.address);
  console.log("balanceToken:", balanceToken);

  if (balanceToken < liquidityAmountToken) {
    console.log("balanceToken is less than liquidityAmountToken, minting tokens...");
    await token.mint(signer.address, liquidityAmountToken - balanceToken);
  }

  const currentBlock = await ethers.provider.getBlock("latest");
  const deadline = currentBlock!.timestamp + 3600 * 24 * 7; // 7 days

  const balanceETH = await ethers.provider.getBalance(signer.address);
  const { gasPrice } = await ethers.provider.getFeeData();
  const gasFee = BigInt(gasPrice!) * 400000n;

  console.log("balanceETH:", balanceETH);

  const balanceUSDC = await usdcToken.balanceOf(signer.address);
  console.log("balanceUSDC:", balanceUSDC);
  if (balanceUSDC < liquidityAmountUSDC) {
    console.log(
      "balanceUSDC is less than liquidityAmountUSDC, buy USDC...",
      liquidityAmountUSDC - balanceUSDC
    );
    // buy USDC via uniswap
    // swap ETH To USDC
    const WETH = await router.WETH();
    const buyUSDCTx = await router.swapETHForExactTokens(
      liquidityAmountUSDC - balanceUSDC,
      [WETH, config.USDC],
      signer.address,
      deadline,
      { value: balanceETH - gasFee * 2n }
    );

    await buyUSDCTx.wait(5);

    const balanceUSDCAfterBuy = await usdcToken.balanceOf(signer.address);
    console.log("balanceUSDCAfterBuy:", balanceUSDCAfterBuy);
    if (balanceUSDCAfterBuy < liquidityAmountUSDC) {
      throw new Error("Failed to buy USDC");
    } else {
      console.log("USDC bought successfully");
    }
  }

  // Approve tokens for router
  console.log("🔐 Approving tokens for router...");
  const tokenApproveTx = await token.approve(config.uniswapV2Router, liquidityAmountToken);
  await tokenApproveTx.wait(5);

  const usdcApproveTx = await usdcToken.approve(config.uniswapV2Router, liquidityAmountUSDC);
  await usdcApproveTx.wait(5);

  // Add liquidity
  console.log("💧 Adding liquidity...");

  const addLiquidityTx = await router.addLiquidity(
    config.token,
    config.USDC,
    liquidityAmountToken,
    liquidityAmountUSDC,
    0, // amountAMin
    0, // amountBMin
    signer.address,
    deadline
  );
  await addLiquidityTx.wait(5);

  // Check pool balances
  const poolBalance = await token.balanceOf(pairAddress);
  const usdcBalance = await usdcToken.balanceOf(pairAddress);
  console.log("📊 Pool balances:");
  console.log("  Token:", ethers.formatEther(poolBalance));
  console.log("  USDC:", ethers.formatUnits(usdcBalance, 6));

  // Check price
  const amounts = await router.getAmountsOut(ethers.parseUnits("100", 6), [
    config.USDC,
    config.token,
  ]);
  const price = 100 / Number(ethers.formatEther(amounts[1]));
  console.log("💲 Price: 1 Token =", price, "USDC");

  // Save pool address to config
  config.pool = pairAddress;
  await writeJsonFile(filePath, config);

  console.log("\n✅ Uniswap pool created successfully!");
  console.log("Pool address:", pairAddress);
  console.log("Pool added to whitelist for token buying");

  // add pool to managerRegistry
  console.log("🔒 Adding pool to managerRegistry...");
  const addPoolToManagerRegistryTx = await managerRegistry.setPoolStatus(pairAddress, true);
  await addPoolToManagerRegistryTx.wait(5);
  console.log("tx hash:", addPoolToManagerRegistryTx.hash);
  console.log("Pool added to managerRegistry successfully");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
  process.exit(1);
});
