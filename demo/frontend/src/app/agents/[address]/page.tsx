"use client";

import { use } from "react";
import { useAgentDetail } from "@/hooks/useAgentDetail";
import {
  shortenAddress,
  roleLabel,
  decodeScoreVector,
  computeWeightedAverage,
  timeAgo,
} from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";
import { Skeleton } from "@/components/ui/Skeleton";
import { ReputationBadge } from "@/components/ui/ReputationBadge";

export default function AgentDetailPage({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address } = use(params);
  const { data, isLoading, error } = useAgentDetail(address);

  if (isLoading) {
    return (
      <main className="mx-auto max-w-3xl px-6 py-10">
        <Skeleton className="mb-6 h-32 w-full" />
        <Skeleton className="h-60 w-full" />
      </main>
    );
  }

  if (error || !data) {
    return (
      <main className="mx-auto max-w-3xl px-6 py-10">
        <div className="rounded-2xl bg-[#FF593C]/10 p-8 text-center text-sm text-[#FF593C]">
          Failed to load agent details
        </div>
      </main>
    );
  }

  const studioEntries = data.StudioAgent ?? [];
  const workSubmissions = data.WorkSubmission ?? [];
  const scoreVectors = data.ScoreVector ?? [];

  // Determine role from first entry
  const primaryRole = studioEntries[0]?.role ?? 0;
  const agentId = studioEntries[0]?.agentId ?? "?";

  // Compute average quality score across all received score vectors
  const allReceivedScores = workSubmissions.flatMap((sub) =>
    (sub.scoreVectors ?? []).map((sv) => {
      const scores = decodeScoreVector(sv.scoreVector);
      return computeWeightedAverage(scores);
    })
  );
  const avgQuality =
    allReceivedScores.length > 0
      ? allReceivedScores.reduce((a, b) => a + b, 0) / allReceivedScores.length
      : null;

  return (
    <main className="mx-auto max-w-3xl px-6 py-10">
      {/* Agent header */}
      <div className="mb-8 rounded-2xl bg-[#131313] p-6">
        <div className="flex items-center gap-4">
          <div
            className={`flex h-12 w-12 items-center justify-center rounded-full text-sm font-bold ${
              primaryRole === 1
                ? "bg-[#A855F7]/15 text-[#A855F7]"
                : "bg-[#FFBF17]/15 text-[#FFBF17]"
            }`}
          >
            {primaryRole === 1 ? "W" : "V"}
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-lg font-semibold text-white">
                Agent #{agentId}
              </h1>
              <span
                className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${
                  primaryRole === 1
                    ? "bg-[#A855F7]/10 text-[#A855F7]"
                    : "bg-[#FFBF17]/10 text-[#FFBF17]"
                }`}
              >
                {roleLabel(primaryRole)}
              </span>
              <ReputationBadge agentId={agentId} showLabel />
            </div>
            <ExplorerLink
              type="address"
              hash={address}
              label={shortenAddress(address, 6)}
              className="text-sm"
            />
          </div>
        </div>

        {/* Stats */}
        <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
            <p className="text-[10px] text-white/[0.38]">Studios</p>
            <p className="mt-1 text-lg font-semibold text-white/65">
              {studioEntries.length}
            </p>
          </div>
          <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
            <p className="text-[10px] text-white/[0.38]">
              {primaryRole === 1 ? "Submissions" : "Scores Given"}
            </p>
            <p className="mt-1 text-lg font-semibold text-white/65">
              {primaryRole === 1 ? workSubmissions.length : scoreVectors.length}
            </p>
          </div>
          <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
            <p className="text-[10px] text-white/[0.38]">Avg Quality</p>
            <p className="mt-1 text-lg font-semibold text-white/65">
              {avgQuality != null ? avgQuality.toFixed(1) : "—"}
            </p>
          </div>
          <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
            <p className="text-[10px] text-white/[0.38]">ERC-8004 Rep</p>
            <div className="mt-1">
              <ReputationBadge agentId={agentId} showLabel />
            </div>
          </div>
        </div>
      </div>

      {/* Participation history */}
      <div className="rounded-2xl bg-[#131313] p-6">
        <h2 className="mb-4 text-sm font-medium text-white/65">
          Participation History
        </h2>
        {studioEntries.length === 0 ? (
          <p className="text-xs text-white/25 text-center">No participation yet</p>
        ) : (
          <div className="space-y-2">
            {studioEntries.map((entry) => (
              <div
                key={entry.id}
                className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-4 py-3"
              >
                <div className="flex items-center gap-3">
                  <span
                    className={`rounded-full px-2 py-0.5 text-[10px] font-medium ${
                      entry.role === 1
                        ? "bg-[#A855F7]/10 text-[#A855F7]"
                        : "bg-[#FFBF17]/10 text-[#FFBF17]"
                    }`}
                  >
                    {roleLabel(entry.role)}
                  </span>
                  {entry.studio_id && (
                    <ExplorerLink
                      type="address"
                      hash={entry.studio_id as string}
                      label={`Studio ${shortenAddress(entry.studio_id as string)}`}
                      className="text-xs"
                    />
                  )}
                </div>
                <div className="flex items-center gap-3 text-xs text-white/25">
                  <span>Stake: {(Number(entry.stake) / 1e18).toFixed(3)} ETH</span>
                  <span>{timeAgo(entry.blockTimestamp)}</span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Work submissions (for workers) */}
      {primaryRole === 1 && workSubmissions.length > 0 && (
        <div className="mt-6 rounded-2xl bg-[#131313] p-6">
          <h2 className="mb-4 text-sm font-medium text-white/65">
            Work Submissions ({workSubmissions.length})
          </h2>
          <div className="space-y-2">
            {workSubmissions.map((sub) => {
              const scores = (sub.scoreVectors ?? []).map((sv) =>
                computeWeightedAverage(decodeScoreVector(sv.scoreVector))
              );
              const avgScore =
                scores.length > 0
                  ? scores.reduce((a, b) => a + b, 0) / scores.length
                  : null;

              return (
                <div
                  key={sub.id}
                  className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-4 py-3"
                >
                  <div>
                    <span className="text-xs font-mono text-white/[0.38]">
                      {sub.dataHash.slice(0, 18)}...
                    </span>
                    <p className="mt-0.5 text-[10px] text-white/25">
                      {(sub.scoreVectors?.length ?? 0)} score
                      {(sub.scoreVectors?.length ?? 0) !== 1 ? "s" : ""} received
                    </p>
                  </div>
                  <div className="text-right text-xs">
                    {avgScore != null && (
                      <span className="font-mono text-white/65">
                        Avg: {avgScore.toFixed(1)}
                      </span>
                    )}
                    <p className="text-[10px] text-white/25">
                      {timeAgo(sub.timestamp)}
                    </p>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Scores given (for verifiers) */}
      {primaryRole === 2 && scoreVectors.length > 0 && (
        <div className="mt-6 rounded-2xl bg-[#131313] p-6">
          <h2 className="mb-4 text-sm font-medium text-white/65">
            Scores Given ({scoreVectors.length})
          </h2>
          <div className="space-y-2">
            {scoreVectors.map((sv) => {
              const scores = decodeScoreVector(sv.scoreVector);
              const wtAvg = computeWeightedAverage(scores);

              return (
                <div
                  key={sv.id}
                  className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-4 py-3"
                >
                  <div>
                    <span className="text-xs text-white/[0.38]">
                      Worker: {sv.worker.slice(0, 10)}...
                    </span>
                    <p className="mt-0.5 text-[10px] text-white/25">
                      {scores.length} dimensions
                    </p>
                  </div>
                  <div className="text-right text-xs">
                    <span className="font-mono text-white/65">
                      Wt avg: {wtAvg.toFixed(1)}
                    </span>
                    <p className="text-[10px] text-white/25">
                      {timeAgo(sv.timestamp)}
                    </p>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </main>
  );
}
