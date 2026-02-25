"use client";

import { useAccount, useReadContract } from "wagmi";
import { formatEther } from "viem";
import { useClaimWinnings } from "@/hooks/useClaimWinnings";
import { MARKET_ADDRESS, MARKET_ABI } from "@/lib/contracts";

export function ClaimButton({
  marketId,
  outcome,
  yesPool,
  noPool,
}: {
  marketId: string;
  outcome: number | null;
  yesPool: string;
  noPool: string;
}) {
  const { address } = useAccount();
  const { claim, isPending } = useClaimWinnings();

  const winningOption = outcome ?? 0;
  const losingOption = winningOption === 0 ? 1 : 0;

  // Read user's bet on winning side
  const { data: winBet } = useReadContract({
    address: MARKET_ADDRESS,
    abi: MARKET_ABI,
    functionName: "getUserBet",
    args: [BigInt(marketId), address!, winningOption as unknown as number],
    query: { enabled: !!address && outcome != null },
  });

  // Read user's bet on losing side
  const { data: loseBet } = useReadContract({
    address: MARKET_ADDRESS,
    abi: MARKET_ABI,
    functionName: "getUserBet",
    args: [BigInt(marketId), address!, losingOption as unknown as number],
    query: { enabled: !!address && outcome != null },
  });

  // Check if already claimed
  const { data: alreadyClaimed } = useReadContract({
    address: MARKET_ADDRESS,
    abi: MARKET_ABI,
    functionName: "claimed",
    args: [BigInt(marketId), address!],
    query: { enabled: !!address },
  });

  if (!address) {
    return (
      <div className="rounded-2xl bg-[#131313] p-5 text-center text-xs text-white/25">
        Connect wallet to check claim eligibility
      </div>
    );
  }

  const userWinBet = winBet ? BigInt(winBet as bigint) : 0n;
  const userLoseBet = loseBet ? BigInt(loseBet as bigint) : 0n;
  const totalBet = userWinBet + userLoseBet;

  // Compute claimable amount: (userBet * totalPool) / winPool
  // outcome 0 = Yes wins (yesPool), outcome 1 = No wins (noPool)
  const winPool = BigInt(winningOption === 0 ? yesPool : noPool);
  const losePool = BigInt(winningOption === 0 ? noPool : yesPool);
  const totalPool = winPool + losePool;
  const claimable =
    winPool > 0n && userWinBet > 0n
      ? (userWinBet * totalPool) / winPool
      : 0n;

  if (totalBet === 0n) {
    return null; // No bet on this market
  }

  if (alreadyClaimed) {
    return (
      <div className="rounded-2xl bg-[#131313] p-5">
        <div className="rounded-xl bg-[#21C95E]/10 p-3 text-center">
          <p className="text-xs text-[#21C95E]">Winnings claimed</p>
        </div>
      </div>
    );
  }

  if (userWinBet === 0n) {
    return (
      <div className="rounded-2xl bg-[#131313] p-5">
        <div className="rounded-xl bg-[#FF593C]/10 p-3 text-center">
          <p className="text-xs text-[#FF593C]">
            You bet on the losing side
          </p>
          <p className="mt-1 text-[10px] text-white/25">
            Your bet: {formatEther(userLoseBet)} ETH on{" "}
            {losingOption === 0 ? "Yes" : "No"}
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="rounded-2xl bg-[#131313] p-5 space-y-3">
      <div className="rounded-xl bg-[#21C95E]/5 p-3">
        <p className="text-xs text-white/[0.38]">Your claimable payout</p>
        <p className="mt-1 text-lg font-bold text-[#21C95E]">
          {parseFloat(formatEther(claimable)).toFixed(4)} ETH
        </p>
        <p className="mt-1 text-[10px] text-white/25">
          Your bet: {formatEther(userWinBet)} ETH on{" "}
          {winningOption === 0 ? "Yes" : "No"}
        </p>
      </div>
      <button
        onClick={() => claim(BigInt(marketId))}
        disabled={isPending}
        className="w-full rounded-2xl bg-[#21C95E] px-4 py-3 text-sm font-semibold text-white transition-all duration-200 hover:bg-[#21C95E]/80 disabled:cursor-not-allowed disabled:opacity-40"
      >
        {isPending ? "Claiming..." : `Claim ${parseFloat(formatEther(claimable)).toFixed(4)} ETH`}
      </button>
    </div>
  );
}
