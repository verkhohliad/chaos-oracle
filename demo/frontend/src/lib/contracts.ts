// ============ Addresses ============

export const MARKET_ADDRESS = (process.env.NEXT_PUBLIC_MARKET_ADDRESS ??
  "0x64A52A8ce57291cA701F18376f26E224F7E2AEcb") as `0x${string}`;

export const REGISTRY_ADDRESS =
  "0x4D067737D50bFeC0da87Cc782eA144Aeb24c05d5" as `0x${string}`;

export const REWARDS_DISTRIBUTOR_ADDRESS =
  "0x11aF07D8933a25B7fa32D06408d77a3ffaDcEAD1" as `0x${string}`;

export const REPUTATION_REGISTRY_ADDRESS =
  "0x8004B8FD1A363aa02fDC07635C0c5F94f6Af5B7E" as `0x${string}`;

export const CHAOSCHAIN_REGISTRY_ADDRESS =
  "0x7F38C1aFFB24F30500d9174ed565110411E42d50" as `0x${string}`;

// ============ ExamplePredictionMarket ABI ============

export const MARKET_ABI = [
  {
    type: "function",
    name: "createMarket",
    inputs: [
      { name: "_question", type: "string" },
      { name: "_deadline", type: "uint256" },
    ],
    outputs: [{ name: "marketId", type: "uint256" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "placeBet",
    inputs: [
      { name: "_marketId", type: "uint256" },
      { name: "_option", type: "uint8" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "claimWinnings",
    inputs: [{ name: "_marketId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "getMarket",
    inputs: [{ name: "_marketId", type: "uint256" }],
    outputs: [
      { name: "creator", type: "address" },
      { name: "_question", type: "string" },
      { name: "deadline", type: "uint256" },
      { name: "yesPool", type: "uint256" },
      { name: "noPool", type: "uint256" },
      { name: "outcome", type: "uint8" },
      { name: "settled", type: "bool" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getUserBet",
    inputs: [
      { name: "_marketId", type: "uint256" },
      { name: "_user", type: "address" },
      { name: "_option", type: "uint8" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "claimed",
    inputs: [
      { name: "", type: "uint256" },
      { name: "", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
] as const;

// ============ StudioProxy ABI (dynamic addresses) ============

export const STUDIO_PROXY_ABI = [
  {
    type: "function",
    name: "getEvidenceCID",
    inputs: [{ name: "dataHash", type: "bytes32" }],
    outputs: [{ name: "evidenceCID", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getScoringCriteria",
    inputs: [],
    outputs: [
      { name: "names", type: "string[]" },
      { name: "weights", type: "uint16[]" },
    ],
    stateMutability: "pure",
  },
  {
    type: "function",
    name: "getAgentId",
    inputs: [{ name: "agent", type: "address" }],
    outputs: [{ name: "agentId", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getWithdrawableBalance",
    inputs: [{ name: "agent", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "withdraw",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// ============ RewardsDistributor ABI ============

export const REWARDS_DISTRIBUTOR_ABI = [
  {
    type: "function",
    name: "getConsensusResult",
    inputs: [{ name: "dataHash", type: "bytes32" }],
    outputs: [
      {
        name: "result",
        type: "tuple",
        components: [
          { name: "dataHash", type: "bytes32" },
          { name: "consensusScores", type: "uint8[]" },
          { name: "totalStake", type: "uint256" },
          { name: "validatorCount", type: "uint256" },
          { name: "timestamp", type: "uint256" },
          { name: "finalized", type: "bool" },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const;

// ============ ERC-8004 Reputation Registry ABI ============

export const REPUTATION_REGISTRY_ABI = [
  {
    type: "function",
    name: "getSummary",
    inputs: [
      { name: "agentId", type: "uint256" },
      { name: "clientAddresses", type: "address[]" },
      { name: "tag1", type: "string" },
      { name: "tag2", type: "string" },
    ],
    outputs: [
      { name: "count", type: "uint64" },
      { name: "summaryValue", type: "int128" },
      { name: "summaryValueDecimals", type: "uint8" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "readFeedback",
    inputs: [
      { name: "agentId", type: "uint256" },
      { name: "clientAddress", type: "address" },
      { name: "feedbackIndex", type: "uint64" },
    ],
    outputs: [
      { name: "value", type: "int128" },
      { name: "valueDecimals", type: "uint8" },
      { name: "tag1", type: "string" },
      { name: "tag2", type: "string" },
      { name: "isRevoked", type: "bool" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getClients",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "", type: "address[]" }],
    stateMutability: "view",
  },
] as const;

// ============ ChaosChainRegistry ABI ============

export const CHAOSCHAIN_REGISTRY_ABI = [
  {
    type: "function",
    name: "getReputationRegistry",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;
