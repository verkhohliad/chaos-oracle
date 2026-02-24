"use client";

import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { MARKET_ABI, MARKET_ADDRESS } from "@/lib/contracts";

export function useClaimWinnings() {
  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  function claim(marketId: bigint) {
    writeContract({
      address: MARKET_ADDRESS,
      abi: MARKET_ABI,
      functionName: "claimWinnings",
      args: [marketId],
    });
  }

  return { claim, isPending, isConfirming, isSuccess, error, hash };
}
