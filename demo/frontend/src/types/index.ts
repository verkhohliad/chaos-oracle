export interface Market {
  id: string;
  marketId: string;
  creator: string;
  question: string;
  options: string[];
  deadline: string;
  yesPool: string;
  noPool: string;
  outcome: number | null;
  proofHash: string | null;
  settled: boolean;
  settlementReward: string;
  registryKey: string;
  studio: Studio | null;
  bets: Bet[];
  claims: Claim[];
  createdAtBlock: string;
  createdAtTimestamp: string;
}

export interface Bet {
  id: string;
  bettor: string;
  option: number;
  amount: string;
  blockTimestamp: string;
  txHash?: string;
}

export interface Claim {
  id: string;
  claimer: string;
  amount: string;
  blockTimestamp: string;
  txHash?: string;
}

export interface Studio {
  id: string;
  studioId: string;
  registryKey: string;
  settled: boolean;
  outcome: number | null;
  proofHash: string | null;
  agents: StudioAgent[];
  workSubmissions: WorkSubmission[];
  scoreVectors: ScoreVector[];
  epochClose: EpochClose | null;
  createdAtBlock: string;
  createdAtTimestamp: string;
  settledAtTimestamp: string | null;
}

export interface StudioAgent {
  id: string;
  agentId: string;
  agentAddress: string;
  role: number;
  stake: string;
  blockTimestamp: string;
  studio_id?: string;
}

export interface WorkSubmission {
  id: string;
  agentId: string;
  agentAddress: string | null;
  dataHash: string;
  threadRoot: string;
  evidenceRoot: string;
  timestamp: string;
  scoreVectors: ScoreVector[];
}

export interface ScoreVector {
  id: string;
  validatorAgentId: string;
  validatorAddress: string | null;
  worker: string;
  scoreVector: string;
  timestamp: string;
}

export interface EpochClose {
  id: string;
  epoch: string;
  workCount: string;
  validatorCount: string;
  blockTimestamp: string;
  txHash: string;
}

export interface EvidencePayload {
  question: string;
  outcome: number;
  outcome_index?: number;
  confidence: number;
  sources: (string | { url: string; title?: string; snippet?: string })[];
  reasoning: string;
  timestamp: string;
  web_search_queries?: string[];
}

export type MarketStatus = "active" | "closed" | "settled";

// ============ Scoring ============

export interface ScoringDimension {
  name: string;
  weight: number;
}

export interface ConsensusData {
  dataHash: string;
  consensusScores: number[];
  totalStake: bigint;
  validatorCount: bigint;
  timestamp: bigint;
  finalized: boolean;
}

// ============ Agent ============

export interface AgentSummary {
  agentAddress: string;
  agentId: string;
  role: number; // 1 = worker, 2 = verifier (StudioProxy AgentRole enum)
  studioCount: number;
  submissionCount: number;
  scoreCount: number;
}
