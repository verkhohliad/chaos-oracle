"use client";

import type { Market } from "@/types";
import {
  getMarketStatus,
  formatEth,
  shortenAddress,
} from "@/lib/utils";
import { Badge } from "@/components/ui/Badge";
import { PoolBar } from "@/components/ui/PoolBar";
import { Countdown } from "@/components/ui/Countdown";

export function MarketHeader({ market }: { market: Market }) {
  const status = getMarketStatus(market);
  const totalVolume = BigInt(market.yesPool) + BigInt(market.noPool);

  return (
    <div className="rounded-2xl bg-[#131313] p-8">
      <div className="mb-5 flex items-start justify-between gap-4">
        <h1 className="text-xl font-semibold tracking-tight text-white">
          {market.question}
        </h1>
        <Badge
          status={status}
          outcome={market.outcome}
          options={market.options}
        />
      </div>

      <div className="mb-6 flex flex-wrap gap-5 text-xs text-white/[0.38]">
        <span>Creator: {shortenAddress(market.creator)}</span>
        <span>Volume: {formatEth(totalVolume.toString())} ETH</span>
        <span>
          Settlement reward: {formatEth(market.settlementReward)} ETH
        </span>
        <Countdown deadline={market.deadline} />
      </div>

      <PoolBar yesPool={market.yesPool} noPool={market.noPool} />
    </div>
  );
}
