import { formatEther } from "viem";
import type { Market, MarketStatus, ScoringDimension } from "@/types";

export function shortenAddress(addr: string, chars = 4): string {
  return `${addr.slice(0, chars + 2)}...${addr.slice(-chars)}`;
}

export function formatEth(wei: string | bigint): string {
  const val = formatEther(typeof wei === "string" ? BigInt(wei) : wei);
  const num = parseFloat(val);
  if (num === 0) return "0";
  if (num < 0.001) return "<0.001";
  return num.toFixed(3);
}

export function getMarketStatus(market: Market): MarketStatus {
  if (market.settled) return "settled";
  const now = Math.floor(Date.now() / 1000);
  if (BigInt(market.deadline) <= BigInt(now)) return "closed";
  return "active";
}

export function statusLabel(status: MarketStatus, outcome: number | null = null, options: string[] = ['Yes', 'No']): string {
  if (status === "settled" && outcome != null && options) {
    return `${options[outcome] ?? `Option ${outcome}`}`;
  }
  if (status === "closed") return "Awaiting Settlement";
  return "Active";
}

export function statusColor(status: MarketStatus): string {
  if (status === "active") return "bg-[#21C95E]/15 text-[#21C95E]";
  if (status === "closed") return "bg-[#FFBF17]/15 text-[#FFBF17]";
  return "bg-[#A855F7]/15 text-[#A855F7]";
}

export function timeAgo(timestamp: string | number): string {
  const seconds = Math.floor(Date.now() / 1000) - Number(timestamp);
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

export function timeUntil(timestamp: string | number): string {
  const seconds = Number(timestamp) - Math.floor(Date.now() / 1000);
  if (seconds <= 0) return "ended";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.floor(seconds / 86400)}d`;
}

export function decodeScoreVector(hex: string): number[] {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  // ABI-encoded: each uint8 sits in a 32-byte (64 hex char) slot, value in last byte
  if (clean.length >= 64) {
    const numSlots = Math.floor(clean.length / 64);
    const scores: number[] = [];
    for (let i = 0; i < numSlots; i++) {
      scores.push(parseInt(clean.slice(i * 64 + 62, i * 64 + 64), 16));
    }
    return scores;
  }
  // Fallback: packed bytes (for any non-ABI data)
  const bytes: number[] = [];
  for (let i = 0; i < clean.length; i += 2) {
    bytes.push(parseInt(clean.slice(i, i + 2), 16));
  }
  return bytes;
}

// ============ Explorer Links ============

const EXPLORER_BASE = "https://sepolia.etherscan.io";

export function explorerUrl(
  type: "tx" | "address" | "block",
  hash: string
): string {
  return `${EXPLORER_BASE}/${type}/${hash}`;
}

// ============ Outcome helpers ============
// Contract: opts[0] = "Yes", opts[1] = "No". outcome 0 = Yes wins, 1 = No wins, 255 = unresolved.

export function outcomeLabel(outcome: number, options?: string[]): string {
  if (options && options[outcome]) return options[outcome];
  if (outcome === 0) return "Yes";
  if (outcome === 1) return "No";
  return `Option ${outcome}`;
}

// ============ Score Dimensions ============
// 9 dimensions from PredictionSettlementLogic.getScoringCriteria()
// Gateway truncates to 5 for on-chain uint8[] storage.

export const SCORE_DIMENSIONS: ScoringDimension[] = [
  { name: "Initiative", weight: 100 },
  { name: "Collaboration", weight: 100 },
  { name: "Reasoning Depth", weight: 100 },
  { name: "Compliance", weight: 100 },
  { name: "Efficiency", weight: 100 },
  // Prediction-specific (higher weights)
  { name: "Accuracy", weight: 200 },
  { name: "Evidence Quality", weight: 150 },
  { name: "Source Diversity", weight: 120 },
  { name: "Reasoning Depth", weight: 130 },
];

export function getScoreDimension(index: number): ScoringDimension {
  return SCORE_DIMENSIONS[index] ?? { name: `Dim ${index}`, weight: 100 };
}

export function computeWeightedAverage(
  scores: number[],
  dimensions?: ScoringDimension[]
): number {
  if (scores.length === 0) return 0;
  const dims = dimensions ?? SCORE_DIMENSIONS;
  let weightedSum = 0;
  let totalWeight = 0;
  for (let i = 0; i < scores.length; i++) {
    const w = dims[i]?.weight ?? 100;
    weightedSum += scores[i] * w;
    totalWeight += w;
  }
  return totalWeight > 0 ? weightedSum / totalWeight : 0;
}

export function scoreColor(score: number): string {
  if (score >= 80) return "bg-[#21C95E]/15 text-[#21C95E]";
  if (score >= 60) return "bg-[#FFBF17]/15 text-[#FFBF17]";
  if (score >= 40) return "bg-[#FF593C]/15 text-[#FF593C]/80";
  return "bg-[#FF593C]/15 text-[#FF593C]";
}

export function roleLabel(role: number): string {
  if (role === 1) return "Worker";
  if (role === 2) return "Verifier";
  if (role === 0) return "None";
  return `Role ${role}`;
}
