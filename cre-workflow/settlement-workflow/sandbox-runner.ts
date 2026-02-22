#!/usr/bin/env bun
/**
 * ChaosOracle Settlement Workflow -- Sandbox Runner (debugging fallback)
 *
 * Standalone Bun CLI that imports core.ts and executes against Anvil directly.
 * Used when `cre workflow simulate` has issues and you need full console.log
 * debugging, breakpoints, and step-by-step execution.
 *
 * Unlike the CRE WASM handlers, this uses native fetch() and viem's
 * walletClient for direct transaction signing.
 *
 * Commands:
 *   check-deadlines  Check for markets past deadline and create studios
 *   settle           Legacy: compute consensus from events (pre-closeEpoch)
 *   settle-finalized NEW: read finalized scores from RewardsDistributor (post-closeEpoch)
 *
 * Usage:
 *   bun run sandbox-runner.ts check-deadlines --rpc http://anvil:8545 --registry 0x... --key 0x...
 *   bun run sandbox-runner.ts settle --rpc http://anvil:8545 --registry 0x... --key 0x... \
 *     --studio 0x... [--ipfs http://ipfs:8080] [--arweave https://arweave.net] [--verbose]
 *   bun run sandbox-runner.ts settle-finalized --rpc http://anvil:8545 --registry 0x... \
 *     --rewards-distributor 0x... --key 0x... --studio 0x... --epoch 1 \
 *     [--ipfs http://ipfs:8080] [--arweave https://arweave.net] [--verbose]
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

import {
  type WorkerSubmission,
  type ConsensusConfig,
  buildEvidenceUrl,
  buildWorkerScoreMap,
  checkConsensusReadiness,
  computeConsensus,
  computeConsensusFromFinalizedScores,
  computeWorkerDataHash,
  countUniqueValidators,
  decodeActiveStudios,
  decodeCanClose,
  decodeConsensusResultData,
  decodeEpochWork,
  decodeMarketsReady,
  decodeWorkSubmitter,
  decodeEvidenceCID,
  decodeWorkParticipants,
  encodeCanCloseStudio,
  encodeCreateStudioForMarket,
  encodeGetActiveStudios,
  encodeGetConsensusResult,
  encodeGetEpochWork,
  encodeGetEvidenceCID,
  encodeGetMarketsReady,
  encodeGetWorkParticipants,
  encodeGetWorkSubmitter,
  encodeSettleWithOutcome,
  ethCall,
  extractDataHashesFromWorkLogs,
  fetchEvidence,
  fetchScoreLogs,
  fetchWorkLogs,
  parseScoreVectorLogs,
  resolveOutcomeFromEvidence,
} from "./core";

import { REGISTRY_ABI } from "../contracts/abi";

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

function parseArgs(): {
  command: string;
  rpc: string;
  registry: Address;
  rewardsDistributor: Address;
  key: `0x${string}`;
  studio?: Address;
  epoch: bigint;
  ipfs: string;
  arweave: string;
  minWorkers: number;
  minValidators: number;
  minScoresPerWorker: number;
  verbose: boolean;
} {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || !["check-deadlines", "settle", "settle-finalized"].includes(command)) {
    console.error("Usage: sandbox-runner.ts <check-deadlines|settle|settle-finalized> [options]");
    process.exit(1);
  }

  const getFlag = (name: string): string | undefined => {
    const idx = args.indexOf(`--${name}`);
    return idx >= 0 ? args[idx + 1] : undefined;
  };

  const rpc = getFlag("rpc") || "http://anvil:8545";
  const registry = (getFlag("registry") || "") as Address;
  const rewardsDistributor = (getFlag("rewards-distributor") || "") as Address;
  const key = (getFlag("key") || "") as `0x${string}`;
  const studio = getFlag("studio") as Address | undefined;
  const epoch = BigInt(getFlag("epoch") || "1");
  const ipfs = getFlag("ipfs") || "http://ipfs:8080";
  const arweave = getFlag("arweave") || "https://arweave.net";
  const minWorkers = parseInt(getFlag("min-workers") || "3", 10);
  const minValidators = parseInt(getFlag("min-validators") || "2", 10);
  const minScoresPerWorker = parseInt(getFlag("min-scores-per-worker") || "2", 10);
  const verbose = args.includes("--verbose");

  if (!registry) {
    console.error("Error: --registry is required");
    process.exit(1);
  }
  if (!key) {
    console.error("Error: --key is required");
    process.exit(1);
  }

  return { command, rpc, registry, rewardsDistributor, key, studio, epoch, ipfs, arweave, minWorkers, minValidators, minScoresPerWorker, verbose };
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async function checkDeadlines(opts: ReturnType<typeof parseArgs>): Promise<void> {
  console.log(`[check-deadlines] Checking markets ready for settlement on ${opts.rpc}...`);

  // Read ready markets
  const readData = await ethCall(opts.rpc, opts.registry, encodeGetMarketsReady());
  const readyKeys = decodeMarketsReady(readData);

  if (readyKeys.length === 0) {
    console.log("[check-deadlines] No markets ready for settlement.");
    return;
  }

  console.log(`[check-deadlines] Found ${readyKeys.length} market(s) ready.`);

  // Create wallet client for transactions
  const account = privateKeyToAccount(opts.key);
  const walletClient = createWalletClient({
    account,
    chain: { ...sepolia, rpcUrls: { default: { http: [opts.rpc] } } },
    transport: http(opts.rpc),
  });

  for (const key of readyKeys) {
    try {
      console.log(`[check-deadlines] Creating studio for market key ${key}`);
      const txData = encodeCreateStudioForMarket(key);

      const hash = await walletClient.sendTransaction({
        to: opts.registry,
        data: txData,
        gas: 6000000n,
      });

      console.log(`[check-deadlines] Studio creation tx: ${hash}`);
    } catch (err) {
      console.error(`[check-deadlines] Failed for key ${key}:`, err);
    }
  }

  console.log(`[check-deadlines] Done. Processed ${readyKeys.length} market(s).`);
}

/**
 * Legacy settle command: computes consensus from raw events (pre-closeEpoch).
 * Kept for backward compatibility and debugging.
 */
async function settle(opts: ReturnType<typeof parseArgs>): Promise<void> {
  const consensusConfig: ConsensusConfig = {
    minWorkers: opts.minWorkers,
    minValidators: opts.minValidators,
    minScoresPerWorker: opts.minScoresPerWorker,
  };

  // If studio not provided, get active studios from registry
  let studioAddresses: string[];
  if (opts.studio) {
    studioAddresses = [opts.studio];
  } else {
    const data = await ethCall(opts.rpc, opts.registry, encodeGetActiveStudios());
    studioAddresses = [...decodeActiveStudios(data)];
  }

  if (studioAddresses.length === 0) {
    console.log("[settle] No active studios found.");
    return;
  }

  console.log(`[settle] Processing ${studioAddresses.length} studio(s)...`);

  const account = privateKeyToAccount(opts.key);
  const walletClient = createWalletClient({
    account,
    chain: { ...sepolia, rpcUrls: { default: { http: [opts.rpc] } } },
    transport: http(opts.rpc),
  });

  let settledCount = 0;

  for (const studioAddress of studioAddresses) {
    try {
      // Gate: canCloseStudio
      const canCloseData = await ethCall(
        opts.rpc, opts.registry,
        encodeCanCloseStudio(studioAddress as Address),
      );
      if (!decodeCanClose(canCloseData)) {
        if (opts.verbose) console.log(`[settle] Studio ${studioAddress}: cannot close. Skipping.`);
        continue;
      }

      // Fetch event logs
      console.log(`[settle] Studio ${studioAddress}: fetching events...`);
      const workLogs = await fetchWorkLogs(opts.rpc, studioAddress);
      const scoreLogs = await fetchScoreLogs(opts.rpc, studioAddress);

      if (opts.verbose) {
        console.log(`[settle]   WorkSubmitted logs: ${workLogs.length}`);
        console.log(`[settle]   ScoreVector logs: ${scoreLogs.length}`);
      }

      if (workLogs.length < consensusConfig.minWorkers) {
        console.log(`[settle] Studio ${studioAddress}: only ${workLogs.length} workers (need ${consensusConfig.minWorkers}). Skipping.`);
        continue;
      }

      // Parse score entries
      const scoreEntries = parseScoreVectorLogs(scoreLogs);
      const uniqueValidators = countUniqueValidators(scoreEntries);

      if (uniqueValidators < consensusConfig.minValidators) {
        console.log(`[settle] Studio ${studioAddress}: only ${uniqueValidators} validators (need ${consensusConfig.minValidators}). Skipping.`);
        continue;
      }

      console.log(`[settle] Studio ${studioAddress}: ${workLogs.length} workers, ${scoreLogs.length} scores from ${uniqueValidators} validators.`);

      // Resolve worker details via on-chain calls
      const dataHashes = extractDataHashesFromWorkLogs(workLogs);
      const workers: WorkerSubmission[] = [];

      for (const { dataHash } of dataHashes) {
        const submitterData = await ethCall(
          opts.rpc, studioAddress,
          encodeGetWorkSubmitter(dataHash),
        );
        const workerAddress = decodeWorkSubmitter(submitterData);
        if (workerAddress === zeroAddress) continue;

        let evidenceCID = "";
        try {
          const cidData = await ethCall(
            opts.rpc, studioAddress,
            encodeGetEvidenceCID(dataHash),
          );
          evidenceCID = decodeEvidenceCID(cidData);
        } catch {
          // Evidence CID not stored on-chain
        }

        workers.push({ agentId: 0n, dataHash, workerAddress, evidenceCID, outcome: -1 });

        if (opts.verbose) {
          console.log(`[settle]   Worker ${workerAddress}: dataHash=${dataHash}, evidenceCID=${evidenceCID || "(none)"}`);
        }
      }

      if (workers.length < consensusConfig.minWorkers) {
        console.log(`[settle] Studio ${studioAddress}: resolved ${workers.length} workers (need ${consensusConfig.minWorkers}). Skipping.`);
        continue;
      }

      // Fetch evidence and resolve outcomes
      for (const worker of workers) {
        if (!worker.evidenceCID) {
          worker.outcome = 0;
          continue;
        }

        const evidenceUrl = buildEvidenceUrl(worker.evidenceCID, opts.ipfs, opts.arweave);
        if (!evidenceUrl) {
          worker.outcome = 0;
          continue;
        }

        try {
          const evidence = await fetchEvidence(evidenceUrl);
          worker.outcome = resolveOutcomeFromEvidence(evidence);
          if (opts.verbose) {
            console.log(`[settle]   Worker ${worker.workerAddress}: outcome=${worker.outcome} (from evidence)`);
          }
        } catch (err) {
          console.log(`[settle]   Failed to fetch evidence for ${worker.workerAddress} (CID: ${worker.evidenceCID}). Defaulting outcome=0.`);
          worker.outcome = 0;
        }
      }

      // Compute consensus
      const workerScores = buildWorkerScoreMap(scoreEntries);

      const readiness = checkConsensusReadiness(
        workers.length, uniqueValidators, workers, workerScores, consensusConfig,
      );
      if (readiness) {
        console.log(`[settle] Studio ${studioAddress}: ${readiness}. Skipping.`);
        continue;
      }

      const { winningOutcome, proofHash, outcomeWeights } = computeConsensus(workers, workerScores);

      console.log(`[settle] Studio ${studioAddress}: consensus outcome=${winningOutcome}, proofHash=${proofHash}`);
      console.log(`[settle]   Outcome weights: ${JSON.stringify(Object.fromEntries(outcomeWeights))}`);

      if (opts.verbose) {
        for (const worker of workers) {
          const scores = workerScores.get(worker.workerAddress.toLowerCase()) || [];
          const avgScore = scores.length > 0 ? (scores.reduce((a, b) => a + b, 0) / scores.length).toFixed(1) : "50.0";
          console.log(`[settle]   Worker ${worker.workerAddress}: outcome=${worker.outcome}, avgScore=${avgScore}`);
        }
      }

      // Settle
      const settleTxData = encodeSettleWithOutcome(
        studioAddress as Address,
        winningOutcome,
        proofHash,
      );

      const hash = await walletClient.sendTransaction({
        to: opts.registry,
        data: settleTxData,
        gas: 500000n,
      });

      settledCount++;
      console.log(`[settle] Studio ${studioAddress}: settlement tx=${hash}`);
    } catch (err) {
      console.error(`[settle] Error processing studio ${studioAddress}:`, err);
    }
  }

  console.log(`[settle] Done. Settled ${settledCount} of ${studioAddresses.length} studio(s).`);
}

/**
 * New settle command: reads finalized scores from RewardsDistributor (post-closeEpoch).
 * This mirrors the CRE onEpochClosed handler.
 */
async function settleFinalized(opts: ReturnType<typeof parseArgs>): Promise<void> {
  if (!opts.rewardsDistributor) {
    console.error("Error: --rewards-distributor is required for settle-finalized");
    process.exit(1);
  }
  if (!opts.studio) {
    console.error("Error: --studio is required for settle-finalized");
    process.exit(1);
  }

  const studioAddress = opts.studio;
  console.log(`[settle-finalized] Studio: ${studioAddress}, Epoch: ${opts.epoch}`);
  console.log(`[settle-finalized] RewardsDistributor: ${opts.rewardsDistributor}`);

  // 1. Get all work hashes for this epoch
  const epochWorkData = await ethCall(
    opts.rpc, opts.rewardsDistributor,
    encodeGetEpochWork(studioAddress, opts.epoch),
  );
  const workHashes = decodeEpochWork(epochWorkData);

  if (workHashes.length === 0) {
    console.log("[settle-finalized] No work hashes found for this epoch.");
    return;
  }

  console.log(`[settle-finalized] Found ${workHashes.length} work submission(s).`);

  // 2. For each dataHash, enumerate workers and read finalized scores
  const workers: WorkerSubmission[] = [];
  const finalizedScores = new Map<string, number[]>();

  for (const dataHash of workHashes) {
    const participantsData = await ethCall(
      opts.rpc, studioAddress,
      encodeGetWorkParticipants(dataHash),
    );
    const participants = decodeWorkParticipants(participantsData);

    let evidenceCID = "";
    try {
      const cidData = await ethCall(opts.rpc, studioAddress, encodeGetEvidenceCID(dataHash));
      evidenceCID = decodeEvidenceCID(cidData);
    } catch {
      // Evidence CID not stored on-chain
    }

    for (const workerAddress of participants) {
      if (workerAddress === zeroAddress) continue;

      // Read finalized quality scores
      const workerDataHash = computeWorkerDataHash(dataHash, workerAddress);
      try {
        const consensusData = await ethCall(
          opts.rpc, opts.rewardsDistributor,
          encodeGetConsensusResult(workerDataHash),
        );
        const result = decodeConsensusResultData(consensusData);

        if (result.finalized) {
          finalizedScores.set(workerAddress.toLowerCase(), result.consensusScores);
          if (opts.verbose) {
            console.log(`[settle-finalized]   Worker ${workerAddress}: finalized scores=[${result.consensusScores.join(",")}], validators=${result.validatorCount}`);
          }
        }
      } catch {
        console.log(`[settle-finalized]   Failed to read consensus for worker ${workerAddress}. Using default weight.`);
      }

      workers.push({ agentId: 0n, dataHash, workerAddress, evidenceCID, outcome: -1 });
    }
  }

  if (workers.length === 0) {
    console.log("[settle-finalized] No workers found. Skipping.");
    return;
  }

  console.log(`[settle-finalized] Resolved ${workers.length} worker(s) with ${finalizedScores.size} finalized score set(s).`);

  // 3. Fetch evidence to extract outcomes
  for (const worker of workers) {
    if (!worker.evidenceCID) {
      worker.outcome = 0;
      continue;
    }

    const evidenceUrl = buildEvidenceUrl(worker.evidenceCID, opts.ipfs, opts.arweave);
    if (!evidenceUrl) {
      worker.outcome = 0;
      continue;
    }

    try {
      const evidence = await fetchEvidence(evidenceUrl);
      worker.outcome = resolveOutcomeFromEvidence(evidence);
      if (opts.verbose) {
        console.log(`[settle-finalized]   Worker ${worker.workerAddress}: outcome=${worker.outcome} (from evidence)`);
      }
    } catch {
      console.log(`[settle-finalized]   Failed to fetch evidence for ${worker.workerAddress}. Defaulting outcome=0.`);
      worker.outcome = 0;
    }
  }

  // 4. Compute consensus using finalized scores
  const { winningOutcome, proofHash, outcomeWeights } = computeConsensusFromFinalizedScores(
    workers, finalizedScores,
  );

  console.log(`[settle-finalized] Consensus outcome=${winningOutcome}, proofHash=${proofHash}`);
  console.log(`[settle-finalized]   Outcome weights: ${JSON.stringify(Object.fromEntries(outcomeWeights))}`);

  // 5. Settle
  const account = privateKeyToAccount(opts.key);
  const walletClient = createWalletClient({
    account,
    chain: { ...sepolia, rpcUrls: { default: { http: [opts.rpc] } } },
    transport: http(opts.rpc),
  });

  const settleTxData = encodeSettleWithOutcome(studioAddress, winningOutcome, proofHash);
  const hash = await walletClient.sendTransaction({
    to: opts.registry,
    data: settleTxData,
    gas: 500000n,
  });

  console.log(`[settle-finalized] Settlement tx: ${hash}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const opts = parseArgs();

  switch (opts.command) {
    case "check-deadlines":
      await checkDeadlines(opts);
      break;
    case "settle":
      await settle(opts);
      break;
    case "settle-finalized":
      await settleFinalized(opts);
      break;
  }
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
