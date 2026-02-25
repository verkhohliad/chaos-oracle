"use client";

import { useState } from "react";
import { useCreateMarket } from "@/hooks/useCreateMarket";
import { ExplorerLink } from "@/components/ui/ExplorerLink";

export function CreateMarketForm() {
  const [question, setQuestion] = useState("");
  const [deadlineStr, setDeadlineStr] = useState("");
  const [amount, setAmount] = useState("");
  const { createMarket, isPending, isConfirming, isSuccess, hash, error } =
    useCreateMarket();

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!question || !deadlineStr || !amount || isPending || isConfirming)
      return;

    const deadlineDate = new Date(deadlineStr);
    const deadlineUnix = BigInt(Math.floor(deadlineDate.getTime() / 1000));

    createMarket(question, deadlineUnix, amount);
  }

  // Default deadline: 5 minutes from now
  const minDeadline = new Date(Date.now() + 60 * 1000)
    .toISOString()
    .slice(0, 16);

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      {/* Question */}
      <div>
        <label className="mb-2 block text-sm font-medium text-white/65">
          Question
        </label>
        <input
          type="text"
          placeholder="Will ETH reach $5,000 by end of March 2026?"
          value={question}
          onChange={(e) => setQuestion(e.target.value)}
          className="w-full rounded-xl bg-[#1F1F1F] px-4 py-3 text-sm text-white placeholder-white/20 transition-colors focus:bg-[#242424] focus:outline-none focus:ring-1 focus:ring-[#A855F7]/50"
        />
        <p className="mt-1.5 text-xs text-white/25">
          Binary Yes/No question. Be specific and verifiable.
        </p>
      </div>

      {/* Deadline */}
      <div>
        <label className="mb-2 block text-sm font-medium text-white/65">
          Deadline
        </label>
        <input
          type="datetime-local"
          min={minDeadline}
          value={deadlineStr}
          onChange={(e) => setDeadlineStr(e.target.value)}
          className="w-full rounded-xl bg-[#1F1F1F] px-4 py-3 text-sm text-white transition-colors focus:bg-[#242424] focus:outline-none focus:ring-1 focus:ring-[#A855F7]/50 [color-scheme:dark]"
        />
        <p className="mt-1.5 text-xs text-white/25">
          Betting closes at this time. Settlement begins after deadline.
        </p>
      </div>

      {/* ETH Amount */}
      <div>
        <label className="mb-2 block text-sm font-medium text-white/65">
          Initial ETH
        </label>
        <input
          type="number"
          step="0.001"
          min="0.001"
          placeholder="0.01"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          className="w-full rounded-xl bg-[#1F1F1F] px-4 py-3 text-sm text-white placeholder-white/20 transition-colors focus:bg-[#242424] focus:outline-none focus:ring-1 focus:ring-[#A855F7]/50"
        />
        <div className="mt-2 rounded-xl bg-[#A855F7]/5 p-3">
          <p className="text-xs text-[#A855F7]/80">
            <span className="font-medium text-[#A855F7]">90%</span> seeds the
            Yes pool as your initial bet &middot;{" "}
            <span className="font-medium text-[#A855F7]">10%</span> goes to AI
            settlement reward
          </p>
          {amount && parseFloat(amount) > 0 && (
            <p className="mt-1 text-xs text-white/25">
              Yes pool: {(parseFloat(amount) * 0.9).toFixed(4)} ETH &middot;
              Settlement reward: {(parseFloat(amount) * 0.1).toFixed(4)} ETH
            </p>
          )}
        </div>
      </div>

      {/* Submit */}
      <button
        type="submit"
        disabled={
          !question || !deadlineStr || !amount || isPending || isConfirming
        }
        className="w-full rounded-2xl bg-[#A855F7] px-4 py-3.5 text-sm font-semibold text-white transition-all duration-200 hover:bg-[#C084FC] disabled:cursor-not-allowed disabled:opacity-40"
      >
        {isPending
          ? "Confirm in wallet..."
          : isConfirming
            ? "Creating market..."
            : "Create Market"}
      </button>

      {/* Error */}
      {error && (
        <div className="rounded-xl bg-[#FF593C]/10 p-3 text-xs text-[#FF593C]">
          {error.message?.includes("DeadlineInPast")
            ? "Deadline must be in the future"
            : error.message?.includes("NoETHSent")
              ? "Must send ETH to create market"
              : error.message?.includes("EmptyQuestion")
                ? "Question cannot be empty"
                : `Error: ${error.message?.slice(0, 100)}`}
        </div>
      )}

      {/* Success */}
      {isSuccess && hash && (
        <div className="rounded-xl bg-[#21C95E]/10 p-4">
          <p className="mb-1 text-sm font-medium text-[#21C95E]">
            Market created successfully!
          </p>
          <ExplorerLink type="tx" hash={hash} className="text-xs" />
        </div>
      )}
    </form>
  );
}
