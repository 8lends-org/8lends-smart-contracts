// get pool info from uniswap v2 router

import { ethers } from "hardhat";
import { readFileSync } from "fs";
import { join } from "path";
import dotenv from "dotenv";
import { formatUnits, parseUnits } from "ethers";

dotenv.config();

// ABI для Uniswap V2 Router
const UNISWAP_ROUTER_ABI = [
    "function swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts)",
    "function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts)",
    "function getReserves() public view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
    "function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts)",
];

const UNISWAP_FACTORY_ABI = [
    "function getPair(address tokenA, address tokenB) public view returns (address pool)",
];

const POOL_ABI = [
    "function getReserves() public view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
    "function token0() public view returns (address)",
    "function token1() public view returns (address)",
];


const main = async () => {
    const net = await ethers.provider.getNetwork();
    console.log("nework: ", net.name);

    const config = JSON.parse(readFileSync(join(__dirname, `../config/${net.chainId}-config.json`), "utf8"));

    if (!config.uniswapV2Router) {
        throw new Error("❌ Uniswap V2 Router address not found in config");
    }

    const uniswapV2Router = new ethers.Contract(config.uniswapV2Router, UNISWAP_ROUTER_ABI, ethers.provider);
    // price, reserve0, reserve1

    const factoryContract = new ethers.Contract(config.uniswapV2Factory, UNISWAP_FACTORY_ABI, ethers.provider);
    const pool = await factoryContract.getPair(config.token, config.usdc);

    const poolContract = new ethers.Contract(pool, POOL_ABI, ethers.provider);

    const token0 = await poolContract.token0();
    const token1 = await poolContract.token1();
    console.log("token0: ", token0);
    console.log("token1: ", token1);
    console.log("__pool: ", pool);

    const reserves = await poolContract.getReserves();

    const reserve0 = formatUnits(reserves[0], token1 === config.token ? 6 : 18);
    const reserve1 = formatUnits(reserves[1], token1 === config.token ? 18 : 6);
    const price = Number(reserve0) / Number(reserve1);
    console.log("price: ", price.toString());
    console.log("token0: ", token1 === config.token ? "USDC" : "TOKEN", reserve0);
    console.log("token1: ", token1 === config.token ? "TOKEN" : "USDC", reserve1);

}

main();