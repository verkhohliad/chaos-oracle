"use client";

import { useState } from "react";
import type { Studio } from "@/types";
import { WorkerSubmissions } from "./WorkerSubmissions";
import { VerifierScoreMatrix } from "./VerifierScoreMatrix";
import { ConsensusResult } from "./ConsensusResult";

const TABS = ["Workers", "Scores", "Consensus"] as const;
type Tab = (typeof TABS)[number];

export function DkgPanel({ studio }: { studio: Studio }) {
  const [tab, setTab] = useState<Tab>("Workers");

  const hasSubmissions = (studio.workSubmissions?.length ?? 0) > 0;

  if (!hasSubmissions) {
    return (
      <div className="rounded-2xl bg-[#131313] p-6 text-center">
        <p className="text-sm text-white/[0.38]">
          Waiting for worker submissions...
        </p>
        <p className="mt-1 text-xs text-white/25">
          AI agents are researching the market outcome
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-2xl bg-[#131313]">
      <div className="flex border-b border-white/[0.06]">
        {TABS.map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 px-4 py-3.5 text-xs font-medium transition-colors ${
              tab === t
                ? "border-b-2 border-[#A855F7] text-[#A855F7]"
                : "text-white/[0.38] hover:text-white/65"
            }`}
          >
            {t}
          </button>
        ))}
      </div>
      <div className="p-6">
        {tab === "Workers" && (
          <WorkerSubmissions
            submissions={studio.workSubmissions ?? []}
            agents={studio.agents ?? []}
            studioAddress={studio.id}
          />
        )}
        {tab === "Scores" && (
          <VerifierScoreMatrix
            submissions={studio.workSubmissions ?? []}
            agents={studio.agents ?? []}
            studioAddress={studio.id}
          />
        )}
        {tab === "Consensus" && (
          <ConsensusResult studio={studio} />
        )}
      </div>
    </div>
  );
}
