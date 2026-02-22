/**
 * ABI fragments for the ChaosOracleRegistry contract.
 *
 * Only the functions and events that the CRE workflow interacts with are
 * included here. Exported as raw ABI arrays (no viem dependency) so this
 * directory can live outside the workflow node_modules tree.
 */

// ---------------------------------------------------------------------------
// Registry read/write functions
// ---------------------------------------------------------------------------

export const REGISTRY_ABI = [
  {
    type: "function",
    name: "getMarketsReadyForSettlement",
    inputs: [],
    outputs: [{ name: "", type: "bytes32[]", internalType: "bytes32[]" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getActiveStudios",
    inputs: [],
    outputs: [{ name: "", type: "address[]", internalType: "address[]" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "canCloseStudio",
    inputs: [{ name: "studio", type: "address", internalType: "address" }],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "createStudioForMarket",
    inputs: [
      { name: "key", type: "bytes32", internalType: "bytes32" },
      { name: "creReport", type: "bytes", internalType: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "settleWithOutcome",
    inputs: [
      { name: "studio", type: "address", internalType: "address" },
      { name: "outcome", type: "uint8", internalType: "uint8" },
      { name: "proofHash", type: "bytes32", internalType: "bytes32" },
      { name: "creReport", type: "bytes", internalType: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// ---------------------------------------------------------------------------
// Registry events (used by LogTrigger definitions)
// ---------------------------------------------------------------------------

export const REGISTRY_EVENTS = [
  {
    type: "event",
    name: "MarketRegistered",
    inputs: [
      { name: "key", type: "bytes32", indexed: true, internalType: "bytes32" },
      { name: "market", type: "address", indexed: true, internalType: "address" },
      { name: "marketId", type: "uint256", indexed: true, internalType: "uint256" },
      { name: "question", type: "string", indexed: false, internalType: "string" },
      { name: "options", type: "string[]", indexed: false, internalType: "string[]" },
      { name: "deadline", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "reward", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "StudioCreated",
    inputs: [
      { name: "key", type: "bytes32", indexed: true, internalType: "bytes32" },
      { name: "studio", type: "address", indexed: true, internalType: "address" },
      { name: "studioId", type: "uint256", indexed: false, internalType: "uint256" },
      { name: "market", type: "address", indexed: true, internalType: "address" },
      { name: "marketId", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "StudioSettled",
    inputs: [
      { name: "studio", type: "address", indexed: true, internalType: "address" },
      { name: "key", type: "bytes32", indexed: true, internalType: "bytes32" },
      { name: "outcome", type: "uint8", indexed: false, internalType: "uint8" },
      { name: "proofHash", type: "bytes32", indexed: false, internalType: "bytes32" },
    ],
    anonymous: false,
  },
] as const;

// ---------------------------------------------------------------------------
// StudioProxy events (read by CRE to compute consensus)
// ---------------------------------------------------------------------------

export const STUDIO_PROXY_EVENTS = [
  {
    type: "event",
    name: "WorkSubmitted",
    inputs: [
      { name: "agentId", type: "uint256", indexed: true, internalType: "uint256" },
      { name: "dataHash", type: "bytes32", indexed: true, internalType: "bytes32" },
      { name: "threadRoot", type: "bytes32", indexed: false, internalType: "bytes32" },
      { name: "evidenceRoot", type: "bytes32", indexed: false, internalType: "bytes32" },
      { name: "timestamp", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "ScoreVectorSubmittedForWorker",
    inputs: [
      { name: "validatorAgentId", type: "uint256", indexed: true, internalType: "uint256" },
      { name: "dataHash", type: "bytes32", indexed: true, internalType: "bytes32" },
      { name: "worker", type: "address", indexed: true, internalType: "address" },
      { name: "scoreVector", type: "bytes", indexed: false, internalType: "bytes" },
      { name: "timestamp", type: "uint256", indexed: false, internalType: "uint256" },
    ],
    anonymous: false,
  },
] as const;

// ---------------------------------------------------------------------------
// StudioProxy view functions (used by CRE settlement)
// ---------------------------------------------------------------------------

export const STUDIO_PROXY_VIEWS = [
  {
    type: "function",
    name: "getWorkSubmitter",
    inputs: [{ name: "dataHash", type: "bytes32", internalType: "bytes32" }],
    outputs: [{ name: "submitter", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getEvidenceCID",
    inputs: [{ name: "dataHash", type: "bytes32", internalType: "bytes32" }],
    outputs: [{ name: "evidenceCID", type: "string", internalType: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getWorkParticipants",
    inputs: [{ name: "dataHash", type: "bytes32", internalType: "bytes32" }],
    outputs: [{ name: "participants", type: "address[]", internalType: "address[]" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "question",
    inputs: [],
    outputs: [{ name: "", type: "string", internalType: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getOptionCount",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
] as const;

// ---------------------------------------------------------------------------
// RewardsDistributor view functions (used by CRE after closeEpoch)
// ---------------------------------------------------------------------------

export const REWARDS_DISTRIBUTOR_ABI = [
  {
    type: "function",
    name: "getEpochWork",
    inputs: [
      { name: "studio", type: "address", internalType: "address" },
      { name: "epoch", type: "uint64", internalType: "uint64" },
    ],
    outputs: [{ name: "workHashes", type: "bytes32[]", internalType: "bytes32[]" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getConsensusResult",
    inputs: [{ name: "dataHash", type: "bytes32", internalType: "bytes32" }],
    outputs: [
      { name: "dataHash", type: "bytes32", internalType: "bytes32" },
      { name: "consensusScores", type: "uint8[]", internalType: "uint8[]" },
      { name: "totalStake", type: "uint256", internalType: "uint256" },
      { name: "validatorCount", type: "uint256", internalType: "uint256" },
      { name: "timestamp", type: "uint256", internalType: "uint256" },
      { name: "finalized", type: "bool", internalType: "bool" },
    ],
    stateMutability: "view",
  },
] as const;
