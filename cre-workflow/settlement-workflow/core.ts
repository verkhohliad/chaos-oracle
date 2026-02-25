/**
 * ChaosOracle Settlement Workflow -- Core business logic.
 *
 * Pure functions with NO CRE SDK dependency. Shared by:
 *   - main.ts (CRE handlers route I/O through SDK, delegate logic here)
 *   - sandbox-runner.ts (Bun CLI uses native fetch + viem walletClient)
 *
 * Functions are grouped:
 *   1. Types & interfaces
 *   2. ABI encoding/decoding helpers (viem)
 *   3. Event log parsing (pure)
 *   4. Evidence resolution (pure + async fetch variants)
 *   5. Consensus computation (pure)
 *   6. RPC fetch helpers (native fetch, for sandbox-runner only)
 */

import {
  type Address,
  decodeAbiParameters,
  decodeFunctionResult,
  encodeFunctionData,
  encodePacked,
  keccak256,
  toBytes,
  toHex,
  zeroAddress,
} from "viem";
import { REGISTRY_ABI, STUDIO_PROXY_EVENTS, STUDIO_PROXY_VIEWS, REWARDS_DISTRIBUTOR_ABI } from "../contracts/abi";

// ---------------------------------------------------------------------------
// 1. Types & interfaces
// ---------------------------------------------------------------------------

/** Raw log from eth_getLogs JSON-RPC response */
export interface RawLog {
  topics: string[];
  data: string;
  address?: string;
  blockNumber?: string;
  transactionHash?: string;
}

/** Parsed worker submission from WorkSubmitted event */
export interface WorkerSubmission {
  agentId: bigint;
  dataHash: `0x${string}`;
  workerAddress: Address;
  evidenceCID: string;
  outcome: number; // -1 = unresolved
}

/** Parsed score entry from ScoreVectorSubmittedForWorker event */
export interface ScoreEntry {
  validatorAgentId: bigint;
  dataHash: `0x${string}`;
  worker: Address;
  scoreVector: number[];
  averageScore: number;
}

/** Consensus computation result */
export interface ConsensusResult {
  winningOutcome: number;
  proofHash: `0x${string}`;
  outcomeWeights: Map<number, number>;
}

/** Threshold config for consensus readiness */
export interface ConsensusConfig {
  minWorkers: number;
  minValidators: number;
  minScoresPerWorker: number;
}

// ---------------------------------------------------------------------------
// 2. ABI encoding/decoding helpers
// ---------------------------------------------------------------------------

export function encodeGetMarketsReady(): `0x${string}` {
  return encodeFunctionData({
    abi: REGISTRY_ABI,
    functionName: "getMarketsReadyForSettlement",
  });
}

export function encodeGetActiveStudios(): `0x${string}` {
  return encodeFunctionData({
    abi: REGISTRY_ABI,
    functionName: "getActiveStudios",
  });
}

export function encodeCanCloseStudio(studio: Address): `0x${string}` {
  return encodeFunctionData({
    abi: REGISTRY_ABI,
    functionName: "canCloseStudio",
    args: [studio],
  });
}

export function encodeCreateStudioForMarket(key: `0x${string}`): `0x${string}` {
  return encodeFunctionData({
    abi: REGISTRY_ABI,
    functionName: "createStudioForMarket",
    args: [key, "0x" as `0x${string}`],
  });
}

export function encodeSettleWithOutcome(
  studio: Address,
  outcome: number,
  proofHash: `0x${string}`,
): `0x${string}` {
  return encodeFunctionData({
    abi: REGISTRY_ABI,
    functionName: "settleWithOutcome",
    args: [studio, outcome, proofHash, "0x" as `0x${string}`],
  });
}

export function encodeGetWorkSubmitter(dataHash: `0x${string}`): `0x${string}` {
  return encodeFunctionData({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getWorkSubmitter",
    args: [dataHash],
  });
}

export function encodeGetEvidenceCID(dataHash: `0x${string}`): `0x${string}` {
  return encodeFunctionData({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getEvidenceCID",
    args: [dataHash],
  });
}

export function decodeMarketsReady(data: `0x${string}`): readonly `0x${string}`[] {
  return decodeFunctionResult({
    abi: REGISTRY_ABI,
    functionName: "getMarketsReadyForSettlement",
    data,
  }) as readonly `0x${string}`[];
}

export function decodeActiveStudios(data: `0x${string}`): readonly `0x${string}`[] {
  return decodeFunctionResult({
    abi: REGISTRY_ABI,
    functionName: "getActiveStudios",
    data,
  }) as readonly `0x${string}`[];
}

export function decodeCanClose(data: `0x${string}`): boolean {
  return decodeFunctionResult({
    abi: REGISTRY_ABI,
    functionName: "canCloseStudio",
    data,
  }) as boolean;
}

export function decodeWorkSubmitter(data: `0x${string}`): Address {
  return decodeFunctionResult({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getWorkSubmitter",
    data,
  }) as Address;
}

export function decodeEvidenceCID(data: `0x${string}`): string {
  return decodeFunctionResult({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getEvidenceCID",
    data,
  }) as string;
}

// -- RewardsDistributor encode/decode helpers (post-closeEpoch) --

export function encodeGetEpochWork(studio: Address, epoch: bigint): `0x${string}` {
  return encodeFunctionData({
    abi: REWARDS_DISTRIBUTOR_ABI,
    functionName: "getEpochWork",
    args: [studio, epoch],
  });
}

export function encodeGetConsensusResult(dataHash: `0x${string}`): `0x${string}` {
  return encodeFunctionData({
    abi: REWARDS_DISTRIBUTOR_ABI,
    functionName: "getConsensusResult",
    args: [dataHash],
  });
}

export function encodeGetWorkValidators(dataHash: `0x${string}`): `0x${string}` {
  return encodeFunctionData({
    abi: REWARDS_DISTRIBUTOR_ABI,
    functionName: "getWorkValidators",
    args: [dataHash],
  });
}

export function encodeGetWorkParticipants(dataHash: `0x${string}`): `0x${string}` {
  return encodeFunctionData({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getWorkParticipants",
    args: [dataHash],
  });
}

export function decodeEpochWork(data: `0x${string}`): readonly `0x${string}`[] {
  return decodeFunctionResult({
    abi: REWARDS_DISTRIBUTOR_ABI,
    functionName: "getEpochWork",
    data,
  }) as readonly `0x${string}`[];
}

/** Decoded on-chain ConsensusResult from RewardsDistributor */
export interface FinalizedConsensusResult {
  dataHash: `0x${string}`;
  consensusScores: number[];
  totalStake: bigint;
  validatorCount: bigint;
  timestamp: bigint;
  finalized: boolean;
}

export function decodeConsensusResultData(data: `0x${string}`): FinalizedConsensusResult {
  const result = decodeFunctionResult({
    abi: REWARDS_DISTRIBUTOR_ABI,
    functionName: "getConsensusResult",
    data,
  }) as {
    dataHash: `0x${string}`;
    consensusScores: readonly number[];
    totalStake: bigint;
    validatorCount: bigint;
    timestamp: bigint;
    finalized: boolean;
  };

  return {
    dataHash: result.dataHash,
    consensusScores: [...result.consensusScores].map(Number),
    totalStake: result.totalStake,
    validatorCount: result.validatorCount,
    timestamp: result.timestamp,
    finalized: result.finalized,
  };
}

export function decodeWorkValidators(data: `0x${string}`): readonly Address[] {
  return decodeFunctionResult({
    abi: REWARDS_DISTRIBUTOR_ABI,
    functionName: "getWorkValidators",
    data,
  }) as readonly Address[];
}

export function decodeWorkParticipants(data: `0x${string}`): readonly Address[] {
  return decodeFunctionResult({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getWorkParticipants",
    data,
  }) as readonly Address[];
}

/** Encode getScoreVectorsForWorker(dataHash, worker) call on StudioProxy */
export function encodeGetScoreVectorsForWorker(
  dataHash: `0x${string}`,
  worker: Address,
): `0x${string}` {
  return encodeFunctionData({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getScoreVectorsForWorker",
    args: [dataHash, worker],
  });
}

/** Decode getScoreVectorsForWorker result — returns [validators[], scoreVectors[]] */
export function decodeScoreVectorsForWorker(
  data: `0x${string}`,
): { validators: readonly Address[]; scoreVectors: readonly `0x${string}`[] } {
  const decoded = decodeFunctionResult({
    abi: STUDIO_PROXY_VIEWS,
    functionName: "getScoreVectorsForWorker",
    data,
  }) as readonly [readonly Address[], readonly `0x${string}`[]];
  return { validators: decoded[0], scoreVectors: decoded[1] };
}

/**
 * Compute the per-worker consensus key used by RewardsDistributor.
 * keccak256(abi.encodePacked(dataHash, worker))
 */
export function computeWorkerDataHash(
  dataHash: `0x${string}`,
  worker: Address,
): `0x${string}` {
  return keccak256(encodePacked(["bytes32", "address"], [dataHash, worker]));
}

// ---------------------------------------------------------------------------
// 3. Event log parsing (pure functions — legacy, used by sandbox-runner)
// ---------------------------------------------------------------------------

/** Compute event topic hashes */
export const WORK_SUBMITTED_TOPIC = keccak256(
  toBytes("WorkSubmitted(uint256,bytes32,bytes32,bytes32,uint256)"),
);

export const SCORE_SUBMITTED_TOPIC = keccak256(
  toBytes("ScoreVectorSubmittedForWorker(uint256,bytes32,address,bytes,uint256)"),
);

/**
 * Extract dataHash values from WorkSubmitted log entries.
 * Returns array of { dataHash } objects. Worker address and evidence CID
 * must be resolved via on-chain calls (see resolveWorkerDetails).
 */
export function extractDataHashesFromWorkLogs(
  workLogs: RawLog[],
): Array<{ dataHash: `0x${string}` }> {
  return workLogs.map((log) => ({
    dataHash: log.topics[2] as `0x${string}`,
  }));
}

/**
 * Parse ScoreVectorSubmittedForWorker logs into ScoreEntry objects.
 * Decodes the ABI-encoded data field to extract score vectors.
 */
export function parseScoreVectorLogs(scoreLogs: RawLog[]): ScoreEntry[] {
  const entries: ScoreEntry[] = [];

  for (const log of scoreLogs) {
    const workerAddr = ("0x" + log.topics[3].slice(26)).toLowerCase() as Address;

    try {
      const decoded = decodeAbiParameters(
        [
          { name: "scoreVector", type: "bytes" },
          { name: "timestamp", type: "uint256" },
        ],
        log.data as `0x${string}`,
      );

      const scoreBytes = decoded[0] as `0x${string}`;
      const scores: number[] = [];
      const hex = scoreBytes.slice(2); // remove 0x
      for (let i = 0; i < hex.length; i += 2) {
        scores.push(parseInt(hex.slice(i, i + 2), 16));
      }

      const avgScore = scores.length > 0
        ? scores.reduce((a, b) => a + b, 0) / scores.length
        : 50;

      entries.push({
        validatorAgentId: BigInt(log.topics[1]),
        dataHash: log.topics[2] as `0x${string}`,
        worker: workerAddr,
        scoreVector: scores,
        averageScore: avgScore,
      });
    } catch {
      // Skip malformed score entries
    }
  }

  return entries;
}

/**
 * Build a map of workerAddress → [avgScore, ...] from parsed score entries.
 */
export function buildWorkerScoreMap(
  scoreEntries: ScoreEntry[],
): Map<string, number[]> {
  const workerScores = new Map<string, number[]>();
  for (const entry of scoreEntries) {
    const key = entry.worker.toLowerCase();
    const existing = workerScores.get(key) || [];
    existing.push(entry.averageScore);
    workerScores.set(key, existing);
  }
  return workerScores;
}

/**
 * Count unique validators from score entries.
 */
export function countUniqueValidators(scoreEntries: ScoreEntry[]): number {
  return new Set(scoreEntries.map((e) => e.validatorAgentId.toString())).size;
}

// ---------------------------------------------------------------------------
// 4. Evidence resolution
// ---------------------------------------------------------------------------

/**
 * Resolve outcome from evidence JSON.
 * Evidence format: { outcome: number, confidence: number, reasoning: string, ... }
 */
export function resolveOutcomeFromEvidence(evidence: unknown): number {
  if (
    evidence &&
    typeof evidence === "object" &&
    "outcome" in evidence &&
    typeof (evidence as Record<string, unknown>).outcome === "number"
  ) {
    return (evidence as Record<string, unknown>).outcome as number;
  }
  return 0; // default
}

/**
 * Build evidence URL from CID and gateway config.
 * Returns null for SHA-256 stub CIDs (no real evidence).
 */
export function buildEvidenceUrl(
  evidenceCID: string,
  ipfsGatewayUrl: string,
  arweaveGatewayUrl: string,
): string | null {
  // Strip ar:// protocol prefix (Gateway stores CIDs as "ar://{txId}")
  const cid = evidenceCID.startsWith("ar://") ? evidenceCID.slice(5) : evidenceCID;

  if (cid.startsWith("Qm") || cid.startsWith("bafy")) {
    return `${ipfsGatewayUrl}/ipfs/${cid}`;
  }
  if (cid.length === 64) {
    // SHA-256 stub CID — no real evidence available
    return null;
  }
  return `${arweaveGatewayUrl}/${cid}`;
}

// ---------------------------------------------------------------------------
// 5. Consensus computation (pure)
// ---------------------------------------------------------------------------

/**
 * Compute score-weighted consensus outcome.
 *
 * Algorithm:
 *   1. For each worker: weightedScore = mean(all validator avgScores for this worker)
 *   2. For each outcome: totalWeight = sum(weightedScore for workers with this outcome)
 *   3. Winner = outcome with highest totalWeight
 *   4. Proof hash = keccak256(sorted evidence CIDs joined by comma)
 */
export function computeConsensus(
  workers: WorkerSubmission[],
  workerScores: Map<string, number[]>,
): ConsensusResult {
  const outcomeWeights = new Map<number, number>();

  for (const worker of workers) {
    if (worker.outcome < 0) continue; // no outcome resolved

    const scores = workerScores.get(worker.workerAddress.toLowerCase()) || [];
    const weight = scores.length > 0
      ? scores.reduce((a, b) => a + b, 0) / scores.length
      : 50; // default weight if no scores

    const currentWeight = outcomeWeights.get(worker.outcome) || 0;
    outcomeWeights.set(worker.outcome, currentWeight + weight);
  }

  // Find winning outcome
  let winningOutcome = 0;
  let maxWeight = 0;
  for (const [outcome, weight] of outcomeWeights.entries()) {
    if (weight > maxWeight) {
      maxWeight = weight;
      winningOutcome = outcome;
    }
  }

  // Compute proof hash from evidence CIDs
  const evidenceCIDs = workers
    .filter((w) => w.evidenceCID)
    .map((w) => w.evidenceCID)
    .sort();
  const proofHash = keccak256(toBytes(evidenceCIDs.join(","))) as `0x${string}`;

  return { winningOutcome, proofHash, outcomeWeights };
}

/**
 * Check if consensus readiness thresholds are met.
 * Returns a reason string if NOT ready, or null if ready.
 */
export function checkConsensusReadiness(
  workerCount: number,
  validatorCount: number,
  workers: WorkerSubmission[],
  workerScores: Map<string, number[]>,
  config: ConsensusConfig,
): string | null {
  if (workerCount < config.minWorkers) {
    return `only ${workerCount} workers (need ${config.minWorkers})`;
  }

  if (validatorCount < config.minValidators) {
    return `only ${validatorCount} validators (need ${config.minValidators})`;
  }

  let workersWithEnoughScores = 0;
  for (const worker of workers) {
    const scores = workerScores.get(worker.workerAddress.toLowerCase()) || [];
    if (scores.length >= config.minScoresPerWorker) {
      workersWithEnoughScores++;
    }
  }

  if (workersWithEnoughScores < config.minWorkers) {
    return `only ${workersWithEnoughScores} workers with >= ${config.minScoresPerWorker} scores (need ${config.minWorkers})`;
  }

  return null; // ready
}

/**
 * Compute score-weighted consensus using finalized on-chain quality scores.
 *
 * After closeEpoch(), RewardsDistributor stores per-worker ConsensusResult
 * with finalized quality scores (9 dimensions). This function uses the average
 * of those finalized scores as each worker's weight in the outcome vote.
 *
 * Algorithm:
 *   1. For each worker: weight = mean(finalized consensusScores)
 *   2. For each outcome: totalWeight = sum(weight for workers with this outcome)
 *   3. Winner = outcome with highest totalWeight
 *   4. Proof hash = keccak256(sorted evidence CIDs joined by comma)
 */
export function computeConsensusFromFinalizedScores(
  workers: WorkerSubmission[],
  finalizedScores: Map<string, number[]>, // workerAddress → consensusScores
): ConsensusResult {
  const outcomeWeights = new Map<number, number>();

  for (const worker of workers) {
    if (worker.outcome < 0) continue;

    const scores = finalizedScores.get(worker.workerAddress.toLowerCase()) || [];
    const weight = scores.length > 0
      ? scores.reduce((a, b) => a + b, 0) / scores.length
      : 50; // default weight if no finalized scores

    const currentWeight = outcomeWeights.get(worker.outcome) || 0;
    outcomeWeights.set(worker.outcome, currentWeight + weight);
  }

  // Find winning outcome
  let winningOutcome = 0;
  let maxWeight = 0;
  for (const [outcome, weight] of outcomeWeights.entries()) {
    if (weight > maxWeight) {
      maxWeight = weight;
      winningOutcome = outcome;
    }
  }

  // Compute proof hash from evidence CIDs
  const evidenceCIDs = workers
    .filter((w) => w.evidenceCID)
    .map((w) => w.evidenceCID)
    .sort();
  const proofHash = keccak256(toBytes(evidenceCIDs.join(","))) as `0x${string}`;

  return { winningOutcome, proofHash, outcomeWeights };
}

// ---------------------------------------------------------------------------
// 6. RPC fetch helpers (native fetch, for sandbox-runner only)
// ---------------------------------------------------------------------------
// These use standard fetch() and are NOT usable inside CRE WASM handlers.
// CRE handlers use HttpCapability.fetch() instead and pass results to the
// pure parsing functions above.
// ---------------------------------------------------------------------------

/**
 * Fetch WorkSubmitted event logs from an RPC endpoint.
 * @param fromBlock Hex block number to start scanning from (default "0x0").
 *                  On Anvil forks, use the deploy block to avoid upstream RPC range limits.
 */
export async function fetchWorkLogs(
  rpcUrl: string,
  studioAddress: string,
  fromBlock = "0x0",
): Promise<RawLog[]> {
  const resp = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_getLogs",
      params: [
        {
          fromBlock,
          toBlock: "latest",
          address: studioAddress,
          topics: [WORK_SUBMITTED_TOPIC],
        },
      ],
      id: 1,
    }),
  });

  const json = await resp.json();
  return (json as { result?: RawLog[] }).result || [];
}

/**
 * Fetch ScoreVectorSubmittedForWorker event logs from an RPC endpoint.
 * @param fromBlock Hex block number to start scanning from (default "0x0").
 */
export async function fetchScoreLogs(
  rpcUrl: string,
  studioAddress: string,
  fromBlock = "0x0",
): Promise<RawLog[]> {
  const resp = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_getLogs",
      params: [
        {
          fromBlock,
          toBlock: "latest",
          address: studioAddress,
          topics: [SCORE_SUBMITTED_TOPIC],
        },
      ],
      id: 2,
    }),
  });

  const json = await resp.json();
  return (json as { result?: RawLog[] }).result || [];
}

/**
 * Fetch evidence JSON from IPFS/Arweave.
 */
export async function fetchEvidence(url: string): Promise<unknown> {
  const resp = await fetch(url, {
    headers: { Accept: "application/json" },
  });
  return resp.json();
}

/**
 * Call a contract view function via JSON-RPC eth_call.
 * Returns the raw hex response data.
 */
export async function ethCall(
  rpcUrl: string,
  to: string,
  data: string,
): Promise<`0x${string}`> {
  const resp = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_call",
      params: [{ to, data }, "latest"],
      id: 1,
    }),
  });

  const json = (await resp.json()) as { result?: string; error?: { message: string } };
  if (json.error) {
    throw new Error(`eth_call failed: ${json.error.message}`);
  }
  return (json.result || "0x") as `0x${string}`;
}
