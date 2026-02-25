"use client";

import { useEffect, useRef } from "react";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseEther } from "viem";
import { MARKET_ADDRESS, MARKET_ABI } from "@/lib/contracts";
import { txToast } from "./useTxToast";

export function useCreateMarket() {
  const {
    writeContract,
    data: hash,
    isPending,
    error,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  const toastRef = useRef<ReturnType<typeof txToast> | null>(null);

  // Toast on submission
  useEffect(() => {
    if (hash && !toastRef.current) {
      toastRef.current = txToast("Creating Market", hash);
    }
  }, [hash]);

  // Toast on confirmation
  useEffect(() => {
    if (isSuccess && toastRef.current) {
      toastRef.current.confirmed(hash);
      toastRef.current = null;
    }
  }, [isSuccess, hash]);

  // Toast on error
  useEffect(() => {
    if (error && toastRef.current) {
      toastRef.current.failed(error.message.slice(0, 80));
      toastRef.current = null;
    }
  }, [error]);

  function createMarket(question: string, deadline: bigint, ethAmount: string) {
    toastRef.current = null;
    writeContract({
      address: MARKET_ADDRESS,
      abi: MARKET_ABI,
      functionName: "createMarket",
      args: [question, deadline],
      value: parseEther(ethAmount),
    });
  }

  return {
    createMarket,
    isPending,
    isConfirming,
    isSuccess,
    hash,
    error,
  };
}
