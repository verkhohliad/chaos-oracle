/**
 * ChaosOracle Settlement Workflow -- CRE entry point.
 *
 * Orchestrates prediction market settlement via three triggers:
 *   1. Cron (every 10 min): Check for markets past deadline → create studios
 *   2. LogTrigger (EpochClosed on RewardsDistributor): Read finalized scores → settleWithOutcome
 *   3. Cron (every 10 min): Check if studios are ready for epoch closing → call Gateway close-epoch
 *
 * Business logic is extracted into core.ts (pure functions, no CRE SDK dep).
 * This file contains thin CRE handler wrappers that route I/O through the SDK
 * and delegate computation to core.ts.
 */

import {
  bytesToHex,
  type CronPayload,
  handler,
  CronCapability,
  EVMClient,
  type EVMLog,
  encodeCallMsg,
  getNetwork,
  hexToBase64,
  HTTPClient,
  json as httpJson,
  LATEST_BLOCK_NUMBER,
  Runner,
  type Runtime,
  TxStatus,
} from "@chainlink/cre-sdk";
import { type Address, toHex, zeroAddress } from "viem";
import { z } from "zod";
import { REGISTRY_ABI } from "../contracts/abi";
import {
  type WorkerSubmission,
  buildEvidenceUrl,
  computeConsensusFromFinalizedScores,
  computeWorkerDataHash,
  decodeConsensusResultData,
  decodeEpochWork,
  decodeEvidenceCID,
  decodeMarketsReady,
  decodeWorkParticipants,
  decodeWorkSubmitter,
  decodeWorkValidators,
  decodeScoreVectorsForWorker,
  encodeCreateStudioForMarket,
  encodeGetActiveStudios,
  decodeActiveStudios,
  encodeGetConsensusResult,
  encodeGetEpochWork,
  encodeGetEvidenceCID,
  encodeGetMarketsReady,
  encodeGetScoreVectorsForWorker,
  encodeGetWorkParticipants,
  encodeGetWorkSubmitter,
  encodeGetWorkValidators,
  encodeSettleWithOutcome,
  resolveOutcomeFromEvidence,
} from "./core";

// ---------------------------------------------------------------------------
// Config schema (validated at startup via Zod)
// ---------------------------------------------------------------------------

const configSchema = z.object({
  registryAddress: z.string(),
  rewardsDistributorAddress: z.string(),
  chainSelectorName: z.string(),
  gasLimit: z.string(),
  minWorkers: z.string().default("2"),
  minValidators: z.string().default("2"),
  minScoresPerWorker: z.string().default("2"),
  rpcUrl: z.string().default(""),
  arweaveGatewayUrl: z.string().default("https://arweave.net"),
  ipfsGatewayUrl: z.string().default("https://ipfs.io"),
  fromBlock: z.string().default("0x0"),
  // Trigger 3: Epoch closing via Gateway
  gatewayUrl: z.string().default(""),
  defaultSignerAddress: z.string().default(""),
});

type Config = z.infer<typeof configSchema>;

// ---------------------------------------------------------------------------
// CRE SDK helpers
// ---------------------------------------------------------------------------

/** Create EVMClient for the configured chain */
function createEvmClient(chainSelectorName: string): EVMClient {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName,
    isTestnet: true,
  });
  if (!network) throw new Error(`Network not found: ${chainSelectorName}`);
  return new EVMClient(network.chainSelector.selector);
}

/** Read a contract view function via CRE SDK */
function evmRead(
  evm: EVMClient,
  runtime: Runtime<Config>,
  to: Address,
  callData: `0x${string}`,
): `0x${string}` {
  const result = evm
    .callContract(runtime, {
      call: encodeCallMsg({ from: zeroAddress, to, data: callData }),
      blockNumber: LATEST_BLOCK_NUMBER,
    })
    .result();
  return bytesToHex(result.data) as `0x${string}`;
}

/** Write via CRE report signing + writeReport */
function evmWrite(
  evm: EVMClient,
  runtime: Runtime<Config>,
  receiver: Address,
  txData: `0x${string}`,
  gasLimit: string,
): void {
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(txData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  const resp = evm
    .writeReport(runtime, {
      receiver,
      report: reportResponse,
      gasConfig: { gasLimit },
    })
    .result();

  if (resp.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`Tx failed: ${resp.errorMessage || resp.txStatus}`);
  }
}

/** Fetch JSON from URL via CRE HTTPClient.
 *  CRE's HTTP capability expects the body as base64-encoded bytes.
 *  We convert the string body → hex (via viem toHex) → base64 (via SDK hexToBase64).
 */
function httpFetchJson(
  http: HTTPClient,
  runtime: Runtime<Config>,
  method: "GET" | "POST",
  url: string,
  body?: string,
): unknown {
  const resp = http
  // @ts-ignore
    .sendRequest(runtime, {
      method,
      url,
      headers: { "Content-Type": "application/json" },
      ...(body ? { body: hexToBase64(toHex(body)) } : {}),
    })
    .result();
  return httpJson(resp);
}

// ---------------------------------------------------------------------------
// Handler 1: Check Deadlines (Cron)
// ---------------------------------------------------------------------------

const onCheckDeadlines = (runtime: Runtime<Config>, _payload: CronPayload): string => {
  const registryAddress = runtime.config.registryAddress as Address;
  const evmConfig = runtime.config;
  const evm = createEvmClient(evmConfig.chainSelectorName);

  runtime.log("[onCheckDeadlines] Checking for markets ready for settlement...");

  // 1. Read: which markets are past deadline?
  const readData = evmRead(evm, runtime, registryAddress, encodeGetMarketsReady());
  const readyKeys = decodeMarketsReady(readData);

  if (readyKeys.length === 0) {
    runtime.log("[onCheckDeadlines] No markets ready for settlement.");
    return "no markets ready";
  }

  runtime.log(`[onCheckDeadlines] Found ${readyKeys.length} market(s) ready for settlement.`);

  // 2. For each ready market: create a studio via CRE report
  for (const key of readyKeys) {
    try {
      runtime.log(`[onCheckDeadlines] Creating studio for market key ${key}`);
      const txData = encodeCreateStudioForMarket(key);
      evmWrite(evm, runtime, registryAddress, txData, evmConfig.gasLimit);
      runtime.log(`[onCheckDeadlines] Studio creation submitted for key ${key}`);
    } catch (err) {
      runtime.log(`[onCheckDeadlines] Failed to create studio for key ${key}: ${String(err)}`);
    }
  }

  runtime.log(`[onCheckDeadlines] Finished processing ${readyKeys.length} market(s).`);
  return `processed ${readyKeys.length} market(s)`;
};

// ---------------------------------------------------------------------------
// Handler 2: Epoch Closed Settlement (LogTrigger on RewardsDistributor)
// ---------------------------------------------------------------------------
// Fires when RewardsDistributor emits EpochClosed(studio, epoch, ...).
// closeEpoch() finalizes per-worker quality scores on-chain. This handler
// reads those finalized scores, fetches evidence from IPFS (sandbox) or
// Arweave (production) to extract each worker's predicted outcome, computes
// score-weighted consensus, and calls settleWithOutcome().
// ---------------------------------------------------------------------------

const onEpochClosed = (runtime: Runtime<Config>, event: EVMLog): string => {
  const registryAddress = runtime.config.registryAddress as Address;
  const rewardsDistributorAddress = runtime.config.rewardsDistributorAddress as Address;
  const evmConfig = runtime.config;
  const evm = createEvmClient(evmConfig.chainSelectorName);
  const http = new HTTPClient();

  runtime.log("[onEpochClosed] EpochClosed event detected.");

  // ------------------------------------------------------------------
  // Step 1: Decode EpochClosed event
  // EpochClosed(address indexed studio, uint64 indexed epoch, uint256 workCount, uint256 validatorCount)
  // ------------------------------------------------------------------
  const topics = event.topics;
  if (topics.length < 3) {
    runtime.log("[onEpochClosed] Missing or malformed log event.");
    return "malformed event";
  }

  const studioAddress = ("0x" + bytesToHex(topics[1]).slice(26)) as Address;
  const epoch = BigInt(bytesToHex(topics[2]));

  runtime.log(`[onEpochClosed] Studio: ${studioAddress}, Epoch: ${epoch}`);

  // ------------------------------------------------------------------
  // Step 2: Get all work hashes for this epoch
  // ------------------------------------------------------------------
  const epochWorkData = evmRead(
    evm, runtime, rewardsDistributorAddress,
    encodeGetEpochWork(studioAddress, epoch),
  );
  const workHashes = decodeEpochWork(epochWorkData);

  if (workHashes.length === 0) {
    runtime.log("[onEpochClosed] No work hashes found for this epoch.");
    return "no work in epoch";
  }

  runtime.log(`[onEpochClosed] Found ${workHashes.length} work submission(s).`);

  // ------------------------------------------------------------------
  // Step 3: For each dataHash, enumerate workers and read finalized scores
  // ------------------------------------------------------------------
  const workers: WorkerSubmission[] = [];
  const finalizedScores = new Map<string, number[]>(); // workerAddress → consensusScores

  for (const dataHash of workHashes) {
    // Get all workers who participated in this submission
    const participantsData = evmRead(
      evm, runtime, studioAddress,
      encodeGetWorkParticipants(dataHash),
    );
    const participants = decodeWorkParticipants(participantsData);

    // Get evidence CID for this submission
    let evidenceCID = "";
    try {
      const cidData = evmRead(
        evm, runtime, studioAddress,
        encodeGetEvidenceCID(dataHash),
      );
      evidenceCID = decodeEvidenceCID(cidData);
    } catch {
      // Evidence CID not stored on-chain (single-agent submitWork)
    }

    for (const workerAddress of participants) {
      if (workerAddress === zeroAddress) continue;

      // Read finalized quality scores from RewardsDistributor
      const workerDataHash = computeWorkerDataHash(dataHash, workerAddress);
      try {
        const consensusData = evmRead(
          evm, runtime, rewardsDistributorAddress,
          encodeGetConsensusResult(workerDataHash),
        );
        const result = decodeConsensusResultData(consensusData);

        if (result.finalized) {
          finalizedScores.set(workerAddress.toLowerCase(), result.consensusScores);
          runtime.log(
            `[onEpochClosed] Worker ${workerAddress}: finalized scores=[${result.consensusScores.join(",")}], validators=${result.validatorCount}`,
          );
        }
      } catch {
        runtime.log(`[onEpochClosed] Failed to read consensus for worker ${workerAddress}. Using default weight.`);
      }

      workers.push({ agentId: 0n, dataHash, workerAddress, evidenceCID, outcome: -1 });
    }
  }

  if (workers.length === 0) {
    runtime.log("[onEpochClosed] No workers found. Skipping settlement.");
    return "no workers";
  }

  runtime.log(`[onEpochClosed] Resolved ${workers.length} worker(s) with ${finalizedScores.size} finalized score set(s).`);

  // ------------------------------------------------------------------
  // Step 4: Fetch evidence from IPFS (sandbox) or Arweave (production)
  // to extract each worker's predicted outcome
  // ------------------------------------------------------------------
  for (const worker of workers) {
    if (!worker.evidenceCID) {
      worker.outcome = 0;
      continue;
    }

    const evidenceUrl = buildEvidenceUrl(
      worker.evidenceCID,
      evmConfig.ipfsGatewayUrl,
      evmConfig.arweaveGatewayUrl,
    );

    if (!evidenceUrl) {
      worker.outcome = 0;
      continue;
    }

    try {
      const evidence = httpFetchJson(http, runtime, "GET", evidenceUrl);
      worker.outcome = resolveOutcomeFromEvidence(evidence);
    } catch {
      runtime.log(`[onEpochClosed] Failed to fetch evidence for worker ${worker.workerAddress} (CID: ${worker.evidenceCID}). Defaulting outcome=0.`);
      worker.outcome = 0;
    }
  }

  // ------------------------------------------------------------------
  // Step 5: Compute consensus using finalized on-chain scores as weights
  // ------------------------------------------------------------------
  const { winningOutcome, proofHash, outcomeWeights } = computeConsensusFromFinalizedScores(
    workers, finalizedScores,
  );

  runtime.log(
    `[onEpochClosed] Studio ${studioAddress}: consensus outcome=${winningOutcome} (weight=${(outcomeWeights.get(winningOutcome) || 0).toFixed(1)}). Outcome weights: ${JSON.stringify(Object.fromEntries(outcomeWeights))}`,
  );

  // ------------------------------------------------------------------
  // Step 6: Settle via CRE report
  // ------------------------------------------------------------------
  const settleTxData = encodeSettleWithOutcome(
    studioAddress,
    winningOutcome,
    proofHash,
  );
  evmWrite(evm, runtime, registryAddress, settleTxData, evmConfig.gasLimit);

  runtime.log(`[onEpochClosed] Studio ${studioAddress}: settled with outcome=${winningOutcome}, proofHash=${proofHash}`);
  return `settled studio ${studioAddress} with outcome=${winningOutcome}`;
};

// ---------------------------------------------------------------------------
// Handler 3: Check Readiness to Close Epoch (Cron → Gateway)
// ---------------------------------------------------------------------------
// Checks active studios for sufficient work+score submissions. When thresholds
// are met, calls the Gateway's close-epoch workflow which invokes
// RewardsDistributor.closeEpoch() using the deployer signer.
// ---------------------------------------------------------------------------

const onReadyToClose = (runtime: Runtime<Config>, _payload: CronPayload): string => {
  const registryAddress = runtime.config.registryAddress as Address;
  const evmConfig = runtime.config;
  const evm = createEvmClient(evmConfig.chainSelectorName);
  const http = new HTTPClient();

  const gatewayUrl = evmConfig.gatewayUrl;
  const defaultSignerAddress = evmConfig.defaultSignerAddress;

  if (!gatewayUrl || !defaultSignerAddress) {
    runtime.log("[onReadyToClose] gatewayUrl or defaultSignerAddress not configured. Skipping.");
    return "not configured";
  }

  runtime.log("[onReadyToClose] Checking active studios for epoch readiness...");

  // 1. Read active studios from registry
  const studiosData = evmRead(evm, runtime, registryAddress, encodeGetActiveStudios());
  const studios = decodeActiveStudios(studiosData);

  if (studios.length === 0) {
    runtime.log("[onReadyToClose] No active studios.");
    return "no active studios";
  }

  runtime.log(`[onReadyToClose] Found ${studios.length} active studio(s).`);

  const minWorkers = parseInt(evmConfig.minWorkers || "2");
  const minScoresPerWorker = parseInt(evmConfig.minScoresPerWorker || "2");
  let closedCount = 0;

  for (const studioAddress of studios) {
    try {
      // 2. Get work hashes for epoch 1
      const rewardsDistributorAddress = evmConfig.rewardsDistributorAddress as Address;
      const epochWorkData = evmRead(
        evm, runtime, rewardsDistributorAddress,
        encodeGetEpochWork(studioAddress as Address, 1n),
      );
      const workHashes = decodeEpochWork(epochWorkData);

      if (workHashes.length < minWorkers) {
        runtime.log(`[onReadyToClose] Studio ${studioAddress}: ${workHashes.length}/${minWorkers} workers. Not ready.`);
        continue;
      }

      // 3. Check score submissions — two-layer validation:
      //    Layer 1: getWorkValidators(dataHash) on RewardsDistributor — verifies
      //             registerValidator() was called (pre-closeEpoch).
      //    Layer 2: getScoreVectorsForWorker(dataHash, worker) on StudioProxy —
      //             verifies actual score vectors exist for every participant.
      //    closeEpoch() checks BOTH: "No validators" (layer 1) and
      //    "No scores for worker" (layer 2). We must verify both.
      let totalScoreCount = 0;
      let allWorkHashesReady = true;
      for (const dataHash of workHashes) {
        try {
          // Layer 1: Check validators registered on RewardsDistributor
          const validatorsData = evmRead(
            evm, runtime, rewardsDistributorAddress,
            encodeGetWorkValidators(dataHash),
          );
          const validators = decodeWorkValidators(validatorsData);
          if (validators.length === 0) {
            allWorkHashesReady = false;
            runtime.log(`[onReadyToClose] Studio ${studioAddress}: dataHash ${dataHash} has 0 validators. Not ready.`);
            break;
          }

          // Layer 2: Check actual score vectors on StudioProxy for each participant
          const participantsData = evmRead(
            evm, runtime, studioAddress as Address,
            encodeGetWorkParticipants(dataHash),
          );
          const participants = decodeWorkParticipants(participantsData);

          let allParticipantsScored = true;
          for (const worker of participants) {
            if (worker === zeroAddress) continue;
            try {
              const scoresData = evmRead(
                evm, runtime, studioAddress as Address,
                encodeGetScoreVectorsForWorker(dataHash, worker),
              );
              const { validators: scoreValidators } = decodeScoreVectorsForWorker(scoresData);
              if (scoreValidators.length === 0) {
                allParticipantsScored = false;
                runtime.log(`[onReadyToClose] Studio ${studioAddress}: dataHash ${dataHash} worker ${worker} has 0 score vectors. Not ready.`);
                break;
              }
            } catch {
              allParticipantsScored = false;
              runtime.log(`[onReadyToClose] Studio ${studioAddress}: failed to read scores for worker ${worker} on dataHash ${dataHash}.`);
              break;
            }
          }

          if (!allParticipantsScored) {
            allWorkHashesReady = false;
            break;
          }

          totalScoreCount += validators.length;
        } catch {
          allWorkHashesReady = false;
          break;
        }
      }

      if (!allWorkHashesReady) {
        continue;
      }

      const requiredScores = minWorkers * minScoresPerWorker; // e.g. 2 * 2 = 4
      if (totalScoreCount < requiredScores) {
        runtime.log(`[onReadyToClose] Studio ${studioAddress}: ${totalScoreCount}/${requiredScores} score submissions. Not ready.`);
        continue;
      }

      // 4. Studio is ready — call Gateway close-epoch
      runtime.log(`[onReadyToClose] Studio ${studioAddress}: READY for epoch close. Calling Gateway...`);
      const closeEpochBody = JSON.stringify({
        studio_address: studioAddress,
        epoch: 1,
        signer_address: defaultSignerAddress,
      });

      try {
        httpFetchJson(http, runtime, "POST", `${gatewayUrl}/workflows/close-epoch`, closeEpochBody);
        closedCount++;
        runtime.log(`[onReadyToClose] Studio ${studioAddress}: close-epoch workflow submitted to Gateway.`);
      } catch (err) {
        runtime.log(`[onReadyToClose] Studio ${studioAddress}: Gateway call failed: ${String(err)}`);
      }
    } catch (err) {
      runtime.log(`[onReadyToClose] Studio ${studioAddress}: error checking readiness: ${String(err)}`);
    }
  }

  return `checked ${studios.length} studio(s), closed ${closedCount}`;
};

// ---------------------------------------------------------------------------
// Workflow initialization & entry point
// ---------------------------------------------------------------------------
// Trigger index mapping (as shown by `cre workflow simulate`):
//   1. cron-trigger@1.0.0 Trigger        → onCheckDeadlines
//   2. evm:ChainSelector:... LogTrigger   → onEpochClosed
//   3. cron-trigger@1.0.0 Trigger        → onReadyToClose
// ---------------------------------------------------------------------------

const initWorkflow = (config: Config) => {
  const cronCapability = new CronCapability();

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.chainSelectorName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Network not found for chain selector name: ${config.chainSelectorName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);

  return [
    // Trigger 1: Check deadlines every 10 minutes
    handler(
      cronCapability.trigger({ schedule: "*/10 * * * *" }),
      onCheckDeadlines,
    ),

    // Trigger 2: Settle on EpochClosed (LogTrigger on RewardsDistributor)
    handler(
      evmClient.logTrigger({
        addresses: [config.rewardsDistributorAddress],
      }),
      onEpochClosed,
    ),

    // Trigger 3: Check epoch readiness every 10 minutes, close via Gateway
    handler(
      cronCapability.trigger({ schedule: "*/10 * * * *" }),
      onReadyToClose,
    ),
  ];
};

export async function main() {
  // @ts-ignore
  const runner = await Runner.newRunner<Config>({ configSchema });
  await runner.run(initWorkflow);
}
