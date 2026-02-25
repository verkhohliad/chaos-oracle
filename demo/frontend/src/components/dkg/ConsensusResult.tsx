"use client";

import type { Studio } from "@/types";
import { decodeScoreVector, computeWeightedAverage, outcomeLabel } from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";
import { ReputationBadge } from "@/components/ui/ReputationBadge";

export function ConsensusResult({ studio }: { studio: Studio }) {
  if (!studio.settled) {
    return (
      <div className="text-center text-xs text-white/25">
        {studio.epochClose
          ? "Epoch closed — waiting for CRE settlement..."
          : "Consensus not yet reached"}
      </div>
    );
  }

  // Compute score-weighted breakdown from available data
  const submissions = studio.workSubmissions ?? [];
  const breakdown = submissions.map((sub) => {
    const allScores = (sub.scoreVectors ?? []).map((sv) =>
      decodeScoreVector(sv.scoreVector)
    );

    // Weighted average across all verifiers for this worker
    let avgScore = 0;
    if (allScores.length > 0) {
      const wtAvgs = allScores.map((scores) => computeWeightedAverage(scores));
      avgScore = wtAvgs.reduce((a, b) => a + b, 0) / wtAvgs.length;
    }

    return {
      agentId: sub.agentId,
      agentAddress: sub.agentAddress,
      dataHash: sub.dataHash,
      avgScore: Math.round(avgScore * 10) / 10,
      verifierCount: allScores.length,
    };
  });

  return (
    <div className="space-y-4">
      {/* Final outcome */}
      <div className="rounded-xl bg-[#21C95E]/10 p-5 text-center">
        <p className="text-xs text-white/[0.38]">Final Outcome</p>
        <p className="mt-1 text-lg font-bold text-[#21C95E]">
          {outcomeLabel(studio.outcome ?? 0)}
        </p>
      </div>

      {/* Worker score breakdown */}
      {breakdown.length > 0 && (
        <div>
          <p className="mb-2 text-xs font-medium text-white/[0.38]">
            Worker Quality Scores (weighted avg across verifiers)
          </p>
          <div className="space-y-1">
            {breakdown.map((w) => (
              <div
                key={w.dataHash}
                className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-4 py-2.5"
              >
                <div className="flex items-center gap-2">
                  <span className="text-xs font-medium text-[#A855F7]">
                    W{w.agentId}
                  </span>
                  {w.agentAddress && (
                    <ExplorerLink
                      type="address"
                      hash={w.agentAddress}
                      className="text-[10px]"
                    />
                  )}
                  <ReputationBadge agentId={w.agentId} />
                </div>
                <div className="flex items-center gap-3 text-xs">
                  <span className="text-white/25">
                    {w.verifierCount} verifier{w.verifierCount !== 1 ? "s" : ""}
                  </span>
                  <span className="font-mono font-medium text-white/65">
                    {w.avgScore}
                  </span>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Proof + Epoch info */}
      <div className="space-y-2 text-xs text-white/25">
        {studio.proofHash && (
          <div className="flex items-center gap-2">
            <span className="text-white/[0.12]">Proof hash:</span>
            <span className="font-mono break-all">
              {studio.proofHash.slice(0, 18)}...
            </span>
          </div>
        )}
        {studio.epochClose && (
          <div className="flex flex-wrap gap-4">
            <span>Workers: {studio.epochClose.workCount}</span>
            <span>Validators: {studio.epochClose.validatorCount}</span>
            <span>Epoch: {studio.epochClose.epoch}</span>
            {studio.epochClose.txHash && (
              <ExplorerLink
                type="tx"
                hash={studio.epochClose.txHash}
                label="Epoch close tx"
                className="text-xs"
              />
            )}
          </div>
        )}
      </div>
    </div>
  );
}
