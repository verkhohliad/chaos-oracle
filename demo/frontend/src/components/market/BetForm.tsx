"use client";

import { useState } from "react";
import { usePlaceBet } from "@/hooks/usePlaceBet";
import type { MarketStatus } from "@/types";

export function BetForm({
  marketId,
  status,
}: {
  marketId: string;
  status: MarketStatus;
}) {
  const [option, setOption] = useState<0 | 1>(1);
  const [amount, setAmount] = useState("");
  const { placeBet, isPending } = usePlaceBet();

  if (status !== "active") return null;

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!amount || isPending) return;
    placeBet(BigInt(marketId), option, amount);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="rounded-2xl bg-[#131313] p-6"
    >
      <h2 className="mb-5 text-sm font-medium text-white/65">Place a bet</h2>

      <div className="mb-5 flex gap-3">
        {/* option 0 = Yes */}
        <button
          type="button"
          onClick={() => setOption(0)}
          className={`flex-1 rounded-xl px-4 py-2.5 text-sm font-medium transition-all duration-200 ${
            option === 0
              ? "bg-[#21C95E]/15 text-[#21C95E]"
              : "bg-white/[0.06] text-white/[0.38] hover:bg-white/[0.1]"
          }`}
        >
          Yes
        </button>
        {/* option 1 = No */}
        <button
          type="button"
          onClick={() => setOption(1)}
          className={`flex-1 rounded-xl px-4 py-2.5 text-sm font-medium transition-all duration-200 ${
            option === 1
              ? "bg-[#FF593C]/15 text-[#FF593C]"
              : "bg-white/[0.06] text-white/[0.38] hover:bg-white/[0.1]"
          }`}
        >
          No
        </button>
      </div>

      <div className="mb-5">
        <label className="mb-1.5 block text-xs text-white/[0.38]">
          Amount (ETH)
        </label>
        <input
          type="number"
          step="0.001"
          min="0"
          placeholder="0.01"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          className="w-full rounded-xl bg-[#1F1F1F] px-4 py-3 text-sm text-white placeholder-white/20 transition-colors focus:bg-[#242424] focus:outline-none focus:ring-1 focus:ring-[#A855F7]/50"
        />
      </div>

      <button
        type="submit"
        disabled={!amount || isPending}
        className="w-full rounded-2xl bg-[#A855F7] px-4 py-3 text-sm font-semibold text-white transition-all duration-200 hover:bg-[#C084FC] disabled:cursor-not-allowed disabled:opacity-40"
      >
        {isPending ? "Confirming..." : `Bet ${option === 0 ? "Yes" : "No"}`}
      </button>
    </form>
  );
}
