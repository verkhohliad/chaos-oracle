"use client";

import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseEther } from "viem";
import { MARKET_ABI, MARKET_ADDRESS } from "@/lib/contracts";

export function usePlaceBet() {
  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  function placeBet(marketId: bigint, option: number, ethAmount: string) {
    writeContract({
      address: MARKET_ADDRESS,
      abi: MARKET_ABI,
      functionName: "placeBet",
      args: [marketId, option],
      value: parseEther(ethAmount),
    });
  }

  return { placeBet, isPending, isConfirming, isSuccess, error, hash };
}
