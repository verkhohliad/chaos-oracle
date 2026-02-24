import type { Studio } from "@/types";
import { decodeScoreVector } from "@/lib/utils";

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

    // Average score across all verifiers for this worker
    let avgScore = 0;
    if (allScores.length > 0) {
      const totalScores = allScores.map((scores) => {
        const sum = scores.reduce((a, b) => a + b, 0);
        return scores.length > 0 ? sum / scores.length : 0;
      });
      avgScore =
        totalScores.reduce((a, b) => a + b, 0) / totalScores.length;
    }

    return {
      agentId: sub.agentId,
      dataHash: sub.dataHash,
      avgScore: Math.round(avgScore * 10) / 10,
    };
  });

  return (
    <div className="space-y-4">
      {/* Final outcome */}
      <div className="rounded-xl bg-[#21C95E]/10 p-5 text-center">
        <p className="text-xs text-white/[0.38]">Final Outcome</p>
        <p className="mt-1 text-lg font-bold text-[#21C95E]">
          {studio.outcome === 0 ? "Yes" : studio.outcome === 1 ? "No" : `Outcome ${studio.outcome}`}
        </p>
      </div>

      {/* Worker score breakdown */}
      {breakdown.length > 0 && (
        <div>
          <p className="mb-2 text-xs font-medium text-white/[0.38]">
            Worker Quality Scores (avg across verifiers)
          </p>
          <div className="space-y-1">
            {breakdown.map((w) => (
              <div
                key={w.dataHash}
                className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-4 py-2.5"
              >
                <span className="text-xs text-white/65">
                  Worker #{w.agentId}
                </span>
                <span className="font-mono text-xs text-white/[0.38]">
                  Avg: {w.avgScore}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Proof + Epoch info */}
      <div className="space-y-2 text-xs text-white/25">
        {studio.proofHash && (
          <div>
            <span className="text-white/[0.12]">Proof hash: </span>
            <span className="font-mono break-all">
              {studio.proofHash}
            </span>
          </div>
        )}
        {studio.epochClose && (
          <div className="flex gap-4">
            <span>Workers: {studio.epochClose.workCount}</span>
            <span>Validators: {studio.epochClose.validatorCount}</span>
            <span>Epoch: {studio.epochClose.epoch}</span>
          </div>
        )}
      </div>
    </div>
  );
}
