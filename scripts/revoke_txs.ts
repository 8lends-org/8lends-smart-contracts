import dotenv from "dotenv";
import type { Signer, TransactionResponse } from "ethers";
import { ethers } from "hardhat";

dotenv.config();

const GAS_LIMIT = 21_000n;
const FEE_NUM = 200n;
const FEE_DEN = 100n;

/**
 * Multiplies base fee by FEE_NUM/FEE_DEN (default 2x) for replacement txs.
 */
function bumpFee(base: bigint): bigint {
    return (base * FEE_NUM + FEE_DEN - 1n) / FEE_DEN;
}

/**
 * Builds fee fields suitable for replace-by-fee (EIP-1559 or legacy gasPrice).
 */
async function buildReplaceFees(): Promise<{
    gasPrice?: bigint;
    maxFeePerGas?: bigint;
    maxPriorityFeePerGas?: bigint;
}> {
    const fee = await ethers.provider.getFeeData();
    if (fee.gasPrice != null && fee.gasPrice > 0n) {
        return { gasPrice: bumpFee(fee.gasPrice) };
    }
    const maxPriorityFeePerGas = bumpFee(fee.maxPriorityFeePerGas ?? 1_000_000_000n);
    const maxFeePerGas = bumpFee(fee.maxFeePerGas ?? fee.gasPrice ?? 100_000_000_000n);
    const floor = maxPriorityFeePerGas * 2n + 1_000_000_000n;
    return {
        maxPriorityFeePerGas,
        maxFeePerGas: maxFeePerGas > floor ? maxFeePerGas : floor,
    };
}

/**
 * Broadcasts all replacement txs in parallel (explicit nonce each). Miners still order by nonce on-chain.
 */
async function broadcastAllCancels(
    signer: Signer,
    nonces: readonly number[],
    fees: { gasPrice?: bigint; maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint }
): Promise<TransactionResponse[]> {
    return Promise.all(
        nonces.map((nonce) =>
            signer.sendTransaction({
                to: ethers.ZeroAddress,
                value: 0n,
                nonce,
                gasLimit: GAS_LIMIT,
                ...fees,
            })
        )
    );
}

async function main(): Promise<void> {
    const [signer] = await ethers.getSigners();
    const address = await signer.getAddress();
    const latest = await ethers.provider.getTransactionCount(address, "latest");
    const pending = await ethers.provider.getTransactionCount(address, "pending");
    if (pending <= latest) {
        console.log(`No queued nonces (latest=${latest}, pending=${pending}).`);
        return;
    }
    const highNonce = pending - 1;
    const nonces: number[] = [];
    for (let n = highNonce; n >= latest; n--) {
        nonces.push(n);
    }
    console.log(
        `Signer ${address}: broadcasting ${nonces.length} cancel tx(s) for nonces ${highNonce}…${latest} (parallel send)`
    );
    const fees = await buildReplaceFees();
    const txs = await broadcastAllCancels(signer, nonces, fees);
    txs.forEach((tx, i) => {
        console.log(`Nonce ${nonces[i]!} → ${tx.hash}`);
    });
    if (process.env.REVOKE_NO_WAIT === "1") {
        console.log("REVOKE_NO_WAIT=1: exiting without waiting for receipts.");
        return;
    }
    const receipts = await Promise.all(txs.map((tx) => tx.wait()));
    receipts.forEach((receipt, i) => {
        console.log(`Nonce ${nonces[i]!} mined in block ${receipt?.blockNumber ?? "?"}`);
    });
    console.log("Done.");
}

main().catch((err: unknown) => {
    console.error(err);
    process.exit(1);
});
