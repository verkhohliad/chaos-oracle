"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchGraphQL } from "./useGraphQL";
import { MARKET_DETAIL_QUERY } from "@/lib/queries";
import type { Market } from "@/types";

interface MarketDetailResponse {
  Market_by_pk: Market | null;
}

export function useMarket(id: string) {
  return useQuery({
    queryKey: ["market", id],
    queryFn: () =>
      fetchGraphQL<MarketDetailResponse>(MARKET_DETAIL_QUERY, { id }),
    select: (data) => data.Market_by_pk,
    enabled: !!id,
  });
}
