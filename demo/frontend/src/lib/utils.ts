import { formatEther } from "viem";
import type { Market, MarketStatus } from "@/types";

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

export function statusLabel(status: MarketStatus, outcome?: number | null, options?: string[]): string {
  if (status === "settled" && outcome != null && options) {
    return `Settled: ${options[outcome] ?? `Option ${outcome}`}`;
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
  const bytes: number[] = [];
  for (let i = 0; i < clean.length; i += 2) {
    bytes.push(parseInt(clean.slice(i, i + 2), 16));
  }
  return bytes;
}

export function evidenceUrl(evidenceRoot: string): string | null {
  if (!evidenceRoot || evidenceRoot === "0x" + "0".repeat(64)) return null;
  const clean = evidenceRoot.startsWith("0x") ? evidenceRoot.slice(2) : evidenceRoot;
  // Arweave tx IDs are 43-char base64url; IPFS CIDs start with Qm or bafy
  // On-chain we store bytes32, so we treat it as an Arweave tx ID hex
  return `https://arweave.net/${clean}`;
}

export const SCORE_DIMENSIONS = [
  "Initiative",
  "Collaboration",
  "Reasoning Depth",
  "Compliance",
  "Efficiency",
];

export function scoreColor(score: number): string {
  if (score >= 80) return "bg-[#21C95E]/15 text-[#21C95E]";
  if (score >= 60) return "bg-[#FFBF17]/15 text-[#FFBF17]";
  if (score >= 40) return "bg-[#FF593C]/15 text-[#FF593C]/80";
  return "bg-[#FF593C]/15 text-[#FF593C]";
}
