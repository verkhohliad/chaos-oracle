"use client";

import { use } from "react";
import { useMarket } from "@/hooks/useMarket";
import { getMarketStatus } from "@/lib/utils";
import { MarketHeader } from "@/components/market/MarketHeader";
import { BetForm } from "@/components/market/BetForm";
import { BetList } from "@/components/market/BetList";
import { MarketTimeline } from "@/components/market/MarketTimeline";
import { ClaimButton } from "@/components/market/ClaimButton";
import { SettlementBreakdown } from "@/components/market/SettlementBreakdown";
import { DkgPanel } from "@/components/dkg/DkgPanel";
import { Skeleton } from "@/components/ui/Skeleton";

export default function MarketDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const { data: market, isLoading, error } = useMarket(id);

  if (isLoading) {
    return (
      <main className="mx-auto max-w-4xl px-6 py-10">
        <Skeleton className="mb-6 h-40 w-full" />
        <div className="grid gap-6 md:grid-cols-3">
          <div className="md:col-span-2 space-y-6">
            <Skeleton className="h-60 w-full" />
            <Skeleton className="h-40 w-full" />
          </div>
          <Skeleton className="h-60 w-full" />
        </div>
      </main>
    );
  }

  if (error || !market) {
    return (
      <main className="mx-auto max-w-4xl px-6 py-10">
        <div className="rounded-2xl bg-[#FF593C]/10 p-8 text-center">
          <p className="text-sm text-[#FF593C]">
            {error ? "Failed to load market" : "Market not found"}
          </p>
        </div>
      </main>
    );
  }

  const status = getMarketStatus(market);

  return (
    <main className="mx-auto max-w-4xl px-6 py-10">
      <MarketHeader market={market} />

      <div className="mt-8 grid gap-6 md:grid-cols-3">
        {/* Left column */}
        <div className="space-y-6 md:col-span-2">
          {status === "closed" && (
            <div className="rounded-2xl bg-[#FFBF17]/10 p-5 text-center">
              <p className="text-sm font-medium text-[#FFBF17]">
                Market closed — waiting for AI settlement
              </p>
              <p className="mt-1 text-xs text-white/25">
                CRE will trigger studio creation and consensus
              </p>
            </div>
          )}

          <BetList bets={market.bets ?? []} />

          {market.studio && <DkgPanel studio={market.studio} />}

          {status === "settled" && <SettlementBreakdown market={market} />}
        </div>

        {/* Right column */}
        <div className="space-y-6">
          <BetForm marketId={market.id} status={status} />

          {status === "settled" && (
            <ClaimButton
              marketId={market.id}
              outcome={market.outcome}
              yesPool={market.yesPool}
              noPool={market.noPool}
            />
          )}

          <MarketTimeline market={market} status={status} />
        </div>
      </div>
    </main>
  );
}
