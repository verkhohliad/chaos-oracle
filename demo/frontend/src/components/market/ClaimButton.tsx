"use client";

import { useClaimWinnings } from "@/hooks/useClaimWinnings";

export function ClaimButton({ marketId }: { marketId: string }) {
  const { claim, isPending } = useClaimWinnings();

  return (
    <button
      onClick={() => claim(BigInt(marketId))}
      disabled={isPending}
      className="w-full rounded-2xl bg-[#21C95E] px-4 py-3 text-sm font-semibold text-white transition-all duration-200 hover:bg-[#21C95E]/80 disabled:cursor-not-allowed disabled:opacity-40"
    >
      {isPending ? "Claiming..." : "Claim Winnings"}
    </button>
  );
}
