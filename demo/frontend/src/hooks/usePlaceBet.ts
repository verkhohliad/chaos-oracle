"use client";

import { useEffect, useRef } from "react";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseEther } from "viem";
import { MARKET_ABI, MARKET_ADDRESS } from "@/lib/contracts";
import { txToast } from "./useTxToast";

export function usePlaceBet() {
  const { writeContract, data: hash, isPending, error } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const toastRef = useRef<ReturnType<typeof txToast> | null>(null);

  useEffect(() => {
    if (hash && !toastRef.current) {
      toastRef.current = txToast("Placing Bet", hash);
    }
  }, [hash]);

  useEffect(() => {
    if (isSuccess && toastRef.current) {
      toastRef.current.confirmed(hash);
      toastRef.current = null;
    }
  }, [isSuccess, hash]);

  useEffect(() => {
    if (error && toastRef.current) {
      toastRef.current.failed(error.message.slice(0, 80));
      toastRef.current = null;
    }
  }, [error]);

  function placeBet(marketId: bigint, option: number, ethAmount: string) {
    toastRef.current = null;
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
