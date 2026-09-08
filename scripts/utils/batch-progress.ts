import { createHash } from "crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { join, resolve } from "path";

/**
 * Resumable progress for scripts that send money in batches.
 *
 * Without it, a run that dies on batch 7 of 20 has to be restarted from batch 1, paying the first
 * six batches a second time. The file records how many batches were confirmed, and the next run
 * skips them.
 *
 * The recipient list is fingerprinted, so progress is only reused for the same list: edit the input
 * and the fingerprint changes, which starts a fresh file instead of silently skipping batches whose
 * contents no longer match.
 */

const STATE_DIR = resolve("./scripts/state");

/** Stable fingerprint of the (recipient, amount) pairs, in the order they will be sent. */
export function inputFingerprint(pairs: readonly (readonly [string, bigint])[]): string {
  const body = pairs.map(([to, amount]) => `${to.toLowerCase()}:${amount.toString()}`).join("\n");
  return createHash("sha256").update(body).digest("hex").slice(0, 16);
}

export interface BatchProgress {
  /** Number of batches already confirmed on chain; the next run starts here. */
  completedBatches: number;
  /** Hash of the last confirmed transaction, for tracing what was actually sent. */
  lastTx?: string;
  /** Recorded so a resume against a changed list is refused rather than misapplied. */
  fingerprint: string;
  batchSize: number;
  totalBatches: number;
}

export interface ProgressHandle {
  path: string;
  /** Batch index to start from. */
  startBatch: number;
  /** Call after a batch is confirmed. */
  record(batchIndex: number, txHash?: string): void;
  /**
   * Call once everything is done. The file is kept, not deleted: a completed run must not be
   * repeated by accident. Delete it by hand to distribute the same list again.
   */
  finish(): void;
}

export function openProgress(params: {
  script: string;
  chainId: bigint | number | string;
  fingerprint: string;
  batchSize: number;
  totalBatches: number;
}): ProgressHandle {
  mkdirSync(STATE_DIR, { recursive: true });
  const path = join(STATE_DIR, `${params.script}-${params.chainId}-${params.fingerprint}.progress.json`);

  let startBatch = 0;
  if (existsSync(path)) {
    const saved = JSON.parse(readFileSync(path, "utf8")) as BatchProgress;
    if (saved.fingerprint !== params.fingerprint || saved.batchSize !== params.batchSize) {
      throw new Error(
        `Progress file does not match this run: ${path}. Delete it to start over.`
      );
    }
    startBatch = saved.completedBatches;
    console.log(
      `Resuming: ${startBatch}/${params.totalBatches} batches already confirmed` +
        (saved.lastTx ? `, last tx ${saved.lastTx}` : "")
    );
  }

  const write = (completedBatches: number, lastTx?: string) => {
    const state: BatchProgress = {
      completedBatches,
      lastTx,
      fingerprint: params.fingerprint,
      batchSize: params.batchSize,
      totalBatches: params.totalBatches,
    };
    writeFileSync(path, JSON.stringify(state, null, 2) + "\n");
  };

  return {
    path,
    startBatch,
    record: (batchIndex, txHash) => write(batchIndex + 1, txHash),
    finish: () => write(params.totalBatches),
  };
}
