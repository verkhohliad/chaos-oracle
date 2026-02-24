import type { WorkSubmission, StudioAgent } from "@/types";
import {
  shortenAddress,
  decodeScoreVector,
  SCORE_DIMENSIONS,
  scoreColor,
} from "@/lib/utils";

export function VerifierScoreMatrix({
  submissions,
  agents,
}: {
  submissions: WorkSubmission[];
  agents: StudioAgent[];
}) {
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

  // Determine max dimension count from data
  const maxDims = Math.max(...allScores.map((s) => s.scores.length));
  const dimensions = SCORE_DIMENSIONS.slice(0, maxDims);

  // Group by worker
  const byWorker = new Map<string, typeof allScores>();
  for (const s of allScores) {
    const key = s.workerAgentId;
    if (!byWorker.has(key)) byWorker.set(key, []);
    byWorker.get(key)!.push(s);
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-xs">
        <thead>
          <tr className="border-b border-white/[0.06] text-left text-white/[0.38]">
            <th className="pb-2 pr-3">Worker</th>
            <th className="pb-2 pr-3">Verifier</th>
            {dimensions.map((dim, i) => (
              <th key={i} className="pb-2 pr-2 text-center" title={dim}>
                {dim.length > 8 ? dim.slice(0, 7) + "…" : dim}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {Array.from(byWorker.entries()).map(([workerId, scores]) => {
            const workerAgent = agentMap.get(workerId);
            return scores.map((sv, rowIdx) => {
              const verifierAgent = agentMap.get(sv.validatorAgentId);
              return (
                <tr
                  key={sv.id}
                  className="border-b border-white/[0.04]"
                >
                  {rowIdx === 0 && (
                    <td
                      className="py-2 pr-3 align-top font-mono text-white/65"
                      rowSpan={scores.length}
                    >
                      <span className="text-[#A855F7]">W{workerId}</span>
                      <br />
                      <span className="text-white/25">
                        {sv.workerAddress
                          ? shortenAddress(sv.workerAddress)
                          : workerAgent
                            ? shortenAddress(workerAgent.agentAddress)
                            : ""}
                      </span>
                    </td>
                  )}
                  <td className="py-2 pr-3 font-mono text-white/[0.38]">
                    V{sv.validatorAgentId}
                    <br />
                    <span className="text-white/25">
                      {sv.validatorAddress
                        ? shortenAddress(sv.validatorAddress)
                        : verifierAgent
                          ? shortenAddress(verifierAgent.agentAddress)
                          : ""}
                    </span>
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
                </tr>
              );
            });
          })}
        </tbody>
      </table>
    </div>
  );
}
