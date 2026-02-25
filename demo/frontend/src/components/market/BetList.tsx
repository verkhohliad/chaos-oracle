import type { Bet } from "@/types";
import { formatEth } from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";

export function BetList({ bets }: { bets: Bet[] }) {
  if (!bets || bets.length === 0) {
    return (
      <div className="rounded-2xl bg-[#131313] p-6 text-center text-xs text-white/25">
        No bets placed yet
      </div>
    );
  }

  return (
    <div className="rounded-2xl bg-[#131313] p-6">
      <h2 className="mb-4 text-sm font-medium text-white/65">
        Bets ({bets.length})
      </h2>
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="border-b border-white/[0.06] text-left text-white/[0.38]">
              <th className="pb-2 pr-4">Bettor</th>
              <th className="pb-2 pr-4">Side</th>
              <th className="pb-2 text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {bets.map((bet) => (
              <tr key={bet.id} className="border-b border-white/[0.04]">
                <td className="py-2.5 pr-4">
                  <ExplorerLink
                    type="address"
                    hash={bet.bettor}
                    className="font-mono text-xs"
                  />
                </td>
                <td className="py-2.5 pr-4">
                  <span
                    className={
                      bet.option === 0 ? "text-[#21C95E]" : "text-[#FF593C]"
                    }
                  >
                    {bet.option === 0 ? "Yes" : "No"}
                  </span>
                </td>
                <td className="py-2.5 text-right text-white/65">
                  {formatEth(bet.amount)} ETH
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
