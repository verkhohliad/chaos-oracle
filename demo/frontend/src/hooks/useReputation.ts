"use client";

import { useReadContract } from "wagmi";
import {
  REPUTATION_REGISTRY_ADDRESS,
  REPUTATION_REGISTRY_ABI,
} from "@/lib/contracts";

export interface ReputationData {
  count: number;
  summaryValue: number;
  summaryValueDecimals: number;
}

/**
 * Read ERC-8004 reputation for an agent.
 * Calls ReputationRegistry.getSummary(agentId, [], "prediction", "")
 */
export function useReputation(agentId?: string) {
  const { data, isLoading, error } = useReadContract({
    address: REPUTATION_REGISTRY_ADDRESS,
    abi: REPUTATION_REGISTRY_ABI,
    functionName: "getSummary",
    args: [
      BigInt(agentId || "0"),
      [] as `0x${string}`[],
      "prediction",
      "",
    ],
    query: {
      enabled: !!agentId && agentId !== "0" && agentId !== "?",
      staleTime: 60_000,
    },
  });

  if (data && Array.isArray(data)) {
    const [count, summaryValue, summaryValueDecimals] = data as [bigint, bigint, number];
    return {
      reputation: {
        count: Number(count),
        summaryValue: Number(summaryValue) / Math.pow(10, Number(summaryValueDecimals || 0)),
        summaryValueDecimals: Number(summaryValueDecimals),
      } as ReputationData,
      isLoading,
      error,
    };
  }

  return { reputation: null, isLoading, error };
}
