"use client";

import type { WorkSubmission, StudioAgent } from "@/types";
import {
  shortenAddress,
  decodeScoreVector,
  scoreColor,
  computeWeightedAverage,
} from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";
import { useScoringCriteria } from "@/hooks/useScoringCriteria";

export function VerifierScoreMatrix({
  submissions,
  agents,
  studioAddress,
}: {
  submissions: WorkSubmission[];
  agents: StudioAgent[];
  studioAddress?: string;
}) {
  const { dimensions } = useScoringCriteria(studioAddress);
  const agentMap = new Map(agents.map((a) => [a.agentId, a]));

  // Collect all score vectors across submissions
  const allScores = submissions.flatMap((sub) =>
    (sub.scoreVectors ?? []).map((sv) => ({
      ...sv,
      workerAgentId: sub.agentId,
      workerAddress: sub.agentAddress,
      scores: decodeScoreVector(sv.scoreVector),
    }))
  );

  if (allScores.length === 0) {
    return (
      <div className="text-center text-xs text-white/25">
        No verifier scores yet
      </div>
    );
  }

  // Use the number of decoded scores to determine columns (should be 5 after ABI fix)
  const maxDims = Math.max(...allScores.map((s) => s.scores.length));
  // Build dimension headers from on-chain data (or fallback)
  const displayDims = Array.from({ length: maxDims }, (_, i) =>
    dimensions[i] ?? { name: `Dim ${i}`, weight: 100 }
  );

  // Group by worker
  const byWorker = new Map<string, typeof allScores>();
  for (const s of allScores) {
    const key = s.workerAgentId;
    if (!byWorker.has(key)) byWorker.set(key, []);
    byWorker.get(key)!.push(s);
  }

  return (
    <div className="space-y-4">
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="border-b border-white/[0.06] text-left text-white/[0.38]">
              <th className="pb-2 pr-3">Worker</th>
              <th className="pb-2 pr-3">Verifier</th>
              {displayDims.map((dim, i) => (
                <th
                  key={i}
                  className="pb-2 pr-2 text-center"
                  title={`${dim.name} (weight: ${dim.weight})`}
                >
                  <div className="leading-tight">
                    <span>{dim.name.length > 8 ? dim.name.slice(0, 7) + "…" : dim.name}</span>
                    <br />
                    <span className="text-[10px] text-white/[0.12]">w:{dim.weight}</span>
                  </div>
                </th>
              ))}
              <th className="pb-2 pl-2 text-center text-[#A855F7]">Wt. Avg</th>
            </tr>
          </thead>
          <tbody>
            {Array.from(byWorker.entries()).map(([workerId, scores]) => {
              const workerAgent = agentMap.get(workerId);
              return scores.map((sv, rowIdx) => {
                const verifierAgent = agentMap.get(sv.validatorAgentId);
                const wtAvg = computeWeightedAverage(sv.scores, displayDims);
                return (
                  <tr
                    key={sv.id}
                    className="border-b border-white/[0.04]"
                  >
                    {rowIdx === 0 && (
                      <td
                        className="py-2 pr-3 align-top"
                        rowSpan={scores.length}
                      >
                        <span className="text-xs font-medium text-[#A855F7]">W{workerId}</span>
                        <br />
                        {(sv.workerAddress || workerAgent?.agentAddress) && (
                          <ExplorerLink
                            type="address"
                            hash={sv.workerAddress ?? workerAgent!.agentAddress}
                            label={shortenAddress(sv.workerAddress ?? workerAgent!.agentAddress)}
                            className="text-[10px]"
                          />
                        )}
                      </td>
                    )}
                    <td className="py-2 pr-3">
                      <span className="text-xs text-white/[0.38]">V{sv.validatorAgentId}</span>
                      <br />
                      {(sv.validatorAddress || verifierAgent?.agentAddress) && (
                        <ExplorerLink
                          type="address"
                          hash={sv.validatorAddress ?? verifierAgent!.agentAddress}
                          label={shortenAddress(sv.validatorAddress ?? verifierAgent!.agentAddress)}
                          className="text-[10px]"
                        />
                      )}
                    </td>
                    {sv.scores.map((score, di) => (
                      <td key={di} className="py-2 pr-2 text-center">
                        <span
                          className={`inline-block min-w-[2rem] rounded-lg px-1 py-0.5 font-mono font-medium ${scoreColor(score)}`}
                        >
                          {score}
                        </span>
                      </td>
                    ))}
                    {/* Fill empty cells if this vector is shorter */}
                    {sv.scores.length < maxDims &&
                      Array.from({
                        length: maxDims - sv.scores.length,
                      }).map((_, i) => (
                        <td key={`empty-${i}`} className="py-2 pr-2 text-center">
                          <span className="text-white/[0.12]">—</span>
                        </td>
                      ))}
                    {/* Weighted average */}
                    <td className="py-2 pl-2 text-center">
                      <span
                        className={`inline-block min-w-[2.5rem] rounded-lg px-1.5 py-0.5 font-mono font-semibold ${scoreColor(Math.round(wtAvg))}`}
                      >
                        {wtAvg.toFixed(1)}
                      </span>
                    </td>
                  </tr>
                );
              });
            })}
          </tbody>
        </table>
      </div>

      {/* Legend */}
      <div className="text-[10px] text-white/[0.12]">
        Weighted avg = Σ(score × weight) / Σ(weight). Gateway truncates 9 dimensions to 5 on-chain.
      </div>
    </div>
  );
}
