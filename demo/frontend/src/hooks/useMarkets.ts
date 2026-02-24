"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchGraphQL } from "./useGraphQL";
import { MARKETS_QUERY } from "@/lib/queries";
import type { Market } from "@/types";

interface MarketsResponse {
  Market: Market[];
}

export function useMarkets(limit = 50) {
  return useQuery({
    queryKey: ["markets", limit],
    queryFn: () =>
      fetchGraphQL<MarketsResponse>(MARKETS_QUERY, { limit, offset: 0 }),
    select: (data) => data.Market,
  });
}
