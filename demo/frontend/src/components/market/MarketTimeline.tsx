"use client";

import type { Market, MarketStatus } from "@/types";

interface Step {
  label: string;
  done: boolean;
  active: boolean;
  detail?: string;
}

function buildSteps(market: Market, status: MarketStatus): Step[] {
  const now = Math.floor(Date.now() / 1000);
  const deadlinePassed = Number(market.deadline) <= now;
  const hasBets = (market.bets?.length ?? 0) > 0;
  const hasStudio = !!market.studio;
  const workerCount =
    market.studio?.workSubmissions?.length ?? 0;
  const hasScores =
    (market.studio?.scoreVectors?.length ?? 0) > 0;
  const epochClosed = !!market.studio?.epochClose;
  const settled = market.settled;

  return [
    {
      label: "Market Created",
      done: true,
      active: false,
    },
    {
      label: "Bets Placed",
      done: hasBets,
      active: !hasBets && !deadlinePassed,
      detail: hasBets ? `${market.bets!.length} bets` : undefined,
    },
    {
      label: "Deadline Passed",
      done: deadlinePassed,
      active: !deadlinePassed,
    },
    {
      label: "Studio Created",
      done: hasStudio,
      active: deadlinePassed && !hasStudio,
      detail: !hasStudio && deadlinePassed ? "Waiting for CRE..." : undefined,
    },
    {
      label: "Workers Submitted",
      done: workerCount >= 3,
      active: hasStudio && workerCount < 3 && !settled,
      detail:
        hasStudio && workerCount > 0
          ? `${workerCount} submissions`
          : undefined,
    },
    {
      label: "Verifiers Scored",
      done: hasScores && epochClosed,
      active: hasStudio && workerCount > 0 && !hasScores && !settled,
      detail: hasScores ? "Scores submitted" : undefined,
    },
    {
      label: "Epoch Closed",
      done: epochClosed,
      active: hasScores && !epochClosed && !settled,
    },
    {
      label: settled
        ? `Settled: ${market.outcome != null && market.options?.[market.outcome] ? market.options[market.outcome] : `Outcome ${market.outcome}`}`
        : "Settlement",
      done: settled,
      active: epochClosed && !settled,
      detail: !settled && epochClosed ? "Waiting for CRE..." : undefined,
    },
  ];
}

export function MarketTimeline({
  market,
  status,
}: {
  market: Market;
  status: MarketStatus;
}) {
  const steps = buildSteps(market, status);

  return (
    <div className="rounded-2xl bg-[#131313] p-6">
      <h2 className="mb-4 text-sm font-medium text-white/65">Timeline</h2>
      <div className="space-y-0">
        {steps.map((step, i) => (
          <div key={step.label} className="flex gap-3">
            {/* Connector line + dot */}
            <div className="flex flex-col items-center">
              <div
                className={`h-3 w-3 rounded-full border-2 ${
                  step.done
                    ? "border-[#21C95E] bg-[#21C95E]"
                    : step.active
                      ? "border-[#A855F7] bg-[#A855F7]/30 animate-pulse"
                      : "border-white/[0.12] bg-white/[0.06]"
                }`}
              />
              {i < steps.length - 1 && (
                <div
                  className={`w-0.5 flex-1 min-h-6 ${
                    step.done ? "bg-[#21C95E]/30" : "bg-white/[0.06]"
                  }`}
                />
              )}
            </div>
            {/* Label */}
            <div className="pb-4">
              <p
                className={`text-xs font-medium ${
                  step.done
                    ? "text-white/65"
                    : step.active
                      ? "text-[#A855F7]"
                      : "text-white/25"
                }`}
              >
                {step.done && "✓ "}
                {step.label}
              </p>
              {step.detail && (
                <p className="mt-0.5 text-xs text-white/25">{step.detail}</p>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
