import fs from "fs";
import dotenv from "dotenv";
import hre, { ethers } from "hardhat";
import { readJsonFile, writeJsonFile } from "../utils/helpers";
import { requireOwner } from "../utils/owner-guard";
import { requireRealNetwork } from "../utils/network-guard";
dotenv.config();

async function main() {
  await requireRealNetwork();
  const net = await ethers.provider.getNetwork();
  console.log("\nNetwork name:", net.name, "\n");
  let filePath = `./scripts/config/${net.chainId}-config.json`;
  let config = await readJsonFile(filePath);

  console.log("\nRemoving liquidity from Token/USDC pool");

  const [signer] = await ethers.getSigners();
  console.log("Signer:", await signer.getAddress());

  const signerBalance = await ethers.provider.getBalance(await signer.getAddress());
  console.log("Signer native balance:", ethers.formatEther(signerBalance));

  // add signer address as pool in managerRegistry
  const managerRegistryContract = await ethers.getContractAt(
    "ManagerRegistry",
    config.ManagerRegistry
  );
  await requireOwner(config.ManagerRegistry, "ManagerRegistry");
  const addPoolToManagerRegistryTx = await managerRegistryContract.setPoolStatus(
    await signer.getAddress(),
    true
  );
  await addPoolToManagerRegistryTx.wait(5);
  console.log("tx hash:", addPoolToManagerRegistryTx.hash);
  console.log("Pool added to managerRegistry successfully");

  // Check for required addresses in config
  if (!config.token) {
    throw new Error("Token address not found in config");
  }
  if (!config.USDC) {
    throw new Error("USDC address not found in config");
  }
  if (!config.uniswapV2Router) {
    throw new Error("uniswapV2Router address not found in config");
  }
  if (!config.uniswapV2Factory) {
    throw new Error("uniswapV2Factory address not found in config");
  }
  if (!config.pool) {
    throw new Error("Pool address not found in config");
  }

  console.log("Token address:", config.token);
  console.log("USDC address:", config.USDC);
  console.log("Router:", config.uniswapV2Router);
  console.log("Factory:", config.uniswapV2Factory);
  console.log("Pool:", config.pool);

  // Get contract instances
  const tokenContract = await ethers.getContractAt("Token", config.token);
  const usdcContract = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.USDC);
  const routerContract = await ethers.getContractAt("IUniswapV2Router02", config.uniswapV2Router);
  const factoryContract = await ethers.getContractAt("IUniswapV2Factory", config.uniswapV2Factory);
  const poolContract = await ethers.getContractAt("IUniswapV2Pair", config.pool);

  // LP token is also an ERC20 token
  const lpTokenContract = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.pool);

  // Check LP token balance
  const lpBalance = await lpTokenContract.balanceOf(await signer.getAddress());
  console.log("LP Token balance:", ethers.formatEther(lpBalance));

  if (lpBalance === 0n) {
    console.log("No LP tokens to remove");
    console.log(lpBalance);
    return;
  }

  // Get total supply of LP tokens
  const totalSupply = await lpTokenContract.totalSupply();
  console.log("Total LP supply:", ethers.formatEther(totalSupply));

  // Get reserves
  const reserves = await poolContract.getReserves();
  const tokenReserve = reserves[0];
  const usdcReserve = reserves[1];

  console.log("Token reserve:", ethers.formatEther(tokenReserve));
  console.log("USDC reserve:", ethers.formatEther(usdcReserve));

  // Calculate amounts to remove (proportional to LP tokens)
  const tokenAmount = (tokenReserve * lpBalance) / totalSupply;
  const usdcAmount = (usdcReserve * lpBalance) / totalSupply;

  console.log("Token amount to remove:", ethers.formatEther(tokenAmount));
  console.log("USDC amount to remove:", ethers.formatEther(usdcAmount));

  // Approve router to spend LP tokens
  console.log("\nApproving router to spend LP tokens...");
  const approveTx = await lpTokenContract.approve(config.uniswapV2Router, lpBalance);
  await approveTx.wait(5);
  console.log("Approval transaction hash:", approveTx.hash);

  // Remove liquidity
  console.log("\nRemoving liquidity...");
  const deadline = Math.floor(Date.now() / 1000) + 60 * 20; // 20 minutes from now

  const removeLiquidityTx = await (routerContract as any).removeLiquidity(
    config.token,
    config.USDC,
    lpBalance,
    tokenAmount, // 5% slippage tolerance
    usdcAmount, // 5% slippage tolerance
    await signer.getAddress(),
    deadline
  );

  console.log("Remove liquidity transaction hash:", removeLiquidityTx.hash);
  const receipt = await removeLiquidityTx.wait();
  console.log("Transaction confirmed in block:", receipt?.blockNumber);

  // Check final balances
  const finalTokenBalance = await tokenContract.balanceOf(await signer.getAddress());
  const finalUsdcBalance = await usdcContract.balanceOf(await signer.getAddress());
  const finalLpBalance = await lpTokenContract.balanceOf(await signer.getAddress());

  console.log("\nFinal balances:");
  console.log("Token balance:", ethers.formatEther(finalTokenBalance));
  console.log("USDC balance:", ethers.formatEther(finalUsdcBalance));
  console.log("LP Token balance:", ethers.formatEther(finalLpBalance));

  // Get final reserves
  const finalReserves = await poolContract.getReserves();
  console.log("\nFinal pool reserves:");
  console.log("Token reserve:", ethers.formatEther(finalReserves[0]));
  console.log("USDC reserve:", ethers.formatEther(finalReserves[1]));

  console.log("\nLiquidity removal completed successfully!");
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
