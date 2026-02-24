import Link from "next/link";
import type { Market } from "@/types";
import { getMarketStatus, formatEth } from "@/lib/utils";
import { Badge } from "@/components/ui/Badge";
import { PoolBar } from "@/components/ui/PoolBar";
import { Countdown } from "@/components/ui/Countdown";

export function MarketCard({ market }: { market: Market }) {
  const status = getMarketStatus(market);

  return (
    <Link href={`/market/${market.id}`}>
      <div className="group rounded-2xl bg-[#131313] p-6 transition-all duration-200 hover:bg-[#1B1B1B]">
        <div className="mb-4 flex items-start justify-between gap-3">
          <h3 className="text-sm font-medium text-white line-clamp-2 transition-colors group-hover:text-white/90">
            {market.question}
          </h3>
          <Badge
            status={status}
            outcome={market.outcome}
            options={market.options}
          />
        </div>

        <div className="mb-4">
          <Countdown deadline={market.deadline} />
        </div>

        <div className="mb-5">
          <PoolBar yesPool={market.yesPool} noPool={market.noPool} />
        </div>

        <div className="flex items-center justify-between text-xs text-white/25">
          <span>
            {formatEth(
              (BigInt(market.yesPool) + BigInt(market.noPool)).toString()
            )}{" "}
            ETH volume
          </span>
          {market.studio && (
            <span className="text-[#A855F7]">Studio active</span>
          )}
        </div>
      </div>
    </Link>
  );
}
