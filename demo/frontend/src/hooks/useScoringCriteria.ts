"use client";

import { useReadContract } from "wagmi";
import { STUDIO_PROXY_ABI } from "@/lib/contracts";
import { SCORE_DIMENSIONS } from "@/lib/utils";
import type { ScoringDimension } from "@/types";

/**
 * Fetch scoring dimensions from on-chain StudioProxy.getScoringCriteria().
 * Falls back to hardcoded SCORE_DIMENSIONS if the call fails.
 */
export function useScoringCriteria(studioAddress?: string) {
  const { data, isLoading, error } = useReadContract({
    address: studioAddress as `0x${string}`,
    abi: STUDIO_PROXY_ABI,
    functionName: "getScoringCriteria",
    query: {
      enabled: !!studioAddress,
      staleTime: Infinity,
    },
  });

  if (data && Array.isArray(data)) {
    const [names, weights] = data as [string[], number[]];
    if (names && names.length > 0) {
      const dimensions: ScoringDimension[] = names.map((name, i) => ({
        name,
        weight: Number(weights[i] ?? 100),
      }));
      return { dimensions, isLoading, error };
    }
  }

  // Fallback to hardcoded
  return { dimensions: SCORE_DIMENSIONS, isLoading, error };
}
