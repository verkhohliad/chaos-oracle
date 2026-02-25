"use client";

import { useReputation } from "@/hooks/useReputation";

export function ReputationBadge({
  agentId,
  showLabel = false,
}: {
  agentId: string;
  showLabel?: boolean;
}) {
  const { reputation, isLoading } = useReputation(agentId);

  if (isLoading) {
    return (
      <span className="inline-block h-4 w-8 animate-pulse rounded bg-white/[0.06]" />
    );
  }

  if (!reputation || reputation.count === 0) {
    return showLabel ? (
      <span className="text-[10px] text-white/[0.12]">No reputation</span>
    ) : null;
  }

  const score = reputation.summaryValue;
  const colorClass =
    score >= 70
      ? "bg-[#21C95E]/15 text-[#21C95E]"
      : score >= 40
        ? "bg-[#FFBF17]/15 text-[#FFBF17]"
        : "bg-[#FF593C]/15 text-[#FF593C]";

  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[10px] font-medium ${colorClass}`}
      title={`ERC-8004 Reputation: ${score.toFixed(1)} (${reputation.count} reviews)`}
    >
      {showLabel && <span>Rep:</span>}
      <span className="font-mono">{score.toFixed(1)}</span>
      <span className="text-white/25">({reputation.count})</span>
    </span>
  );
}
