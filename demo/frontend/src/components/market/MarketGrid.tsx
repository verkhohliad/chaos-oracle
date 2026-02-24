"use client";

import { useMarkets } from "@/hooks/useMarkets";
import { MarketCard } from "./MarketCard";
import { MarketCardSkeleton } from "@/components/ui/Skeleton";

export function MarketGrid() {
  const { data, isLoading, error } = useMarkets();
  const markets = data ?? [];

  if (isLoading) {
    return (
      <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <MarketCardSkeleton key={i} />
        ))}
      </div>
    );
  }

  if (error) {
    return (
      <div className="rounded-2xl bg-[#FF593C]/10 p-8 text-center">
        <p className="text-sm text-[#FF593C]">Failed to load markets</p>
        <p className="mt-1 text-xs text-white/25">{error.message}</p>
      </div>
    );
  }

  if (markets.length === 0) {
    return (
      <div className="rounded-2xl bg-[#131313] p-12 text-center">
        <p className="text-sm text-white/[0.38]">No markets found</p>
        <p className="mt-1 text-xs text-white/25">
          Markets will appear here once created on-chain
        </p>
      </div>
    );
  }

  return (
    <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
      {markets.map((market) => (
        <MarketCard key={market.id} market={market} />
      ))}
    </div>
  );
}
