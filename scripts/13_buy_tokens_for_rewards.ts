import dotenv from "dotenv";
import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";

dotenv.config();

// Swap parameters (can be changed)
// The exact amount of tokens to buy is obtained from the environment variable
const TOKEN_AMOUNT_TO_BUY = process.env.TOKEN_AMOUNT_TO_BUY;

// Uniswap V2 Router ABI
const UNISWAP_ROUTER_ABI = [
    "function swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts)",
    "function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts)",
];

// ERC20 Token ABI
const ERC20_ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function balanceOf(address account) external view returns (uint256)",
    "function decimals() external view returns (uint8)",
    "function symbol() external view returns (string)",
];

/**
 * Script for purchasing 8LENDS tokens via Uniswap V2 Router.
 * Buys an exact number of tokens using the available USDC balance.
 */
async function main(): Promise<void> {
    const net = await ethers.provider.getNetwork();
    console.log("network: ", net.name);

    const config: {
        uniswapV2Router: string;
        usdc: string;
        token: string;
        RewardSystem: string;
    } = JSON.parse(readFileSync(join(__dirname, `./config/${net.chainId}-config.json`), "utf8"));

    if (!config.uniswapV2Router) {
        throw new Error("❌ Uniswap V2 Router address not found in config");
    }
    if (!config.usdc) {
        throw new Error("❌ USDC address not found in config");
    }
    if (!config.token) {
        throw new Error("❌ Token address not found in config");
    }

    console.log("\n" + "=".repeat(80));
    console.log(`🌐 Network: ${net.name} (chainId: ${net.chainId})`);
    console.log(`📍 Uniswap Router: ${config.uniswapV2Router}`);
    console.log(`📍 USDC: ${config.usdc}`);
    console.log(`📍 Token: ${config.token}`);
    console.log("=".repeat(80) + "\n");

    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();
    console.log(`👤 Signer: ${signerAddress}\n`);

    let nonce = await ethers.provider.getTransactionCount(signerAddress);

    // Connect to the contracts
    const uniswapRouter = new ethers.Contract(config.uniswapV2Router, UNISWAP_ROUTER_ABI, signer);
    const usdcContract = new ethers.Contract(config.usdc, ERC20_ABI, signer);
    const tokenContract = new ethers.Contract(config.token, ERC20_ABI, signer);

    // Fetch token information
    const usdcDecimals = await usdcContract.decimals();
    const tokenDecimals = await tokenContract.decimals();
    const tokenSymbol = await tokenContract.symbol();

    console.log(`💵 USDC decimals: ${usdcDecimals}`);
    console.log(`🪙 ${tokenSymbol} decimals: ${tokenDecimals}\n`);

    // Check signer's USDC balance
    const usdcBalance = await usdcContract.balanceOf(signerAddress);
    console.log(`💰 SIGNER USDC Balance: ${ethers.formatUnits(usdcBalance, usdcDecimals)} USDC`);

    if (usdcBalance === 0n) {
        throw new Error(`❌ Insufficient USDC balance. Balance is 0 USDC`);
    }

    // Check RewardSystem token balance before swap
    const tokenBalanceBefore = await tokenContract.balanceOf(config.RewardSystem);
    console.log(`🪙 REWARD SYSTEM TOKENS, Balance Before: ${ethers.formatUnits(tokenBalanceBefore, tokenDecimals)} ${tokenSymbol}\n`);

    // Maximum allowed slippage in percent (0.5%)
    const SLIPPAGE_TOLERANCE = 0.5;

    if (!TOKEN_AMOUNT_TO_BUY) {
        throw new Error("❌ TOKEN_AMOUNT_TO_BUY is not set");
    }
    const amountOut = ethers.parseUnits(TOKEN_AMOUNT_TO_BUY, tokenDecimals);

    // Prepare token swap path (USDC -> TOKEN)
    const path = [config.usdc, config.token];
    console.log("path:", path);
    console.log("amountOut:", amountOut);

    // Get required amount of USDC for desired amount of tokens
    const amountsIn = await uniswapRouter.getAmountsIn(amountOut, path);
    const expectedAmountIn = amountsIn[0];

    console.log(`📊 Expected USDC needed: ${ethers.formatUnits(expectedAmountIn, usdcDecimals)} USDC`);

    // Calculate the maximum allowed USDC to spend, including slippage
    const amountInMax = (expectedAmountIn * BigInt(Math.floor((100 + SLIPPAGE_TOLERANCE) * 100))) / 10000n;
    console.log(`📊 Maximum USDC (${SLIPPAGE_TOLERANCE}% slippage): ${ethers.formatUnits(amountInMax, usdcDecimals)} USDC\n`);

    if (usdcBalance < amountInMax) {
        throw new Error(
            `❌ Insufficient USDC balance. Need max ${ethers.formatUnits(amountInMax, usdcDecimals)} USDC, have ${ethers.formatUnits(usdcBalance, usdcDecimals)} USDC`
        );
    }

    // Approve USDC for the router (using the max amount accounting for slippage)
    console.log(`🔓 Approving ${ethers.formatUnits(amountInMax, usdcDecimals)} USDC for Uniswap Router...`);
    const approveTx = await usdcContract.approve(config.uniswapV2Router, amountInMax, { nonce });
    console.log(`   ⏳ Approve transaction sent: ${approveTx.hash}`);
    await approveTx.wait();
    nonce++;
    console.log(`   ✅ Approve confirmed\n`);

    // Execute token swap
    // Deadline is 20 minutes from current Unix timestamp
    const deadline = Math.floor(Date.now() / 1000) + 60 * 20;

    console.log(`🔄 Buying exactly ${TOKEN_AMOUNT_TO_BUY} ${tokenSymbol} for USDC...`);

    const swapTx = await uniswapRouter.swapTokensForExactTokens(
        amountOut,
        amountInMax,
        path,
        config.RewardSystem,
        deadline
    );

    console.log(`   ⏳ Swap transaction sent: ${swapTx.hash}`);
    const receipt = await swapTx.wait();
    nonce++;
    console.log(`   ✅ Swap confirmed in block ${receipt?.blockNumber}`);
    console.log(`   ⛽ Gas used: ${receipt?.gasUsed.toString()}\n`);

    // Check balances after swap
    const tokenBalanceAfter = await tokenContract.balanceOf(config.RewardSystem);
    const usdcBalanceAfter = await usdcContract.balanceOf(signerAddress);
    const tokensReceived = tokenBalanceAfter - tokenBalanceBefore;
    const usdcSpent = usdcBalance - usdcBalanceAfter;

    console.log("=".repeat(80));
    console.log(`✅ Swap completed successfully!`);
    console.log(`🪙 ${tokenSymbol} Balance After: ${ethers.formatUnits(tokenBalanceAfter, tokenDecimals)} ${tokenSymbol}`);
    console.log(`💎 Tokens Received: ${ethers.formatUnits(tokensReceived, tokenDecimals)} ${tokenSymbol}`);
    console.log(`💵 USDC Spent: ${ethers.formatUnits(usdcSpent, usdcDecimals)} USDC`);
    console.log(`💰 USDC Balance After: ${ethers.formatUnits(usdcBalanceAfter, usdcDecimals)} USDC`);
    console.log("=".repeat(80) + "\n");
}

main().catch((error) => {
    console.error("\n❌ Critical error:", error);
    process.exitCode = 1;
});
