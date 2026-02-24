"use client";

import { useState } from "react";
import type { WorkSubmission, StudioAgent } from "@/types";
import { shortenAddress, evidenceUrl } from "@/lib/utils";
import { EvidenceViewer } from "./EvidenceViewer";

export function WorkerSubmissions({
  submissions,
  agents,
}: {
  submissions: WorkSubmission[];
  agents: StudioAgent[];
}) {
  const [expanded, setExpanded] = useState<string | null>(null);

  const agentMap = new Map(
    agents.map((a) => [a.agentId, a])
  );

  return (
    <div className="space-y-3">
      {submissions.map((sub) => {
        const agent = agentMap.get(sub.agentId);
        const evUrl = evidenceUrl(sub.evidenceRoot);
        const isOpen = expanded === sub.id;

        return (
          <div
            key={sub.id}
            className="rounded-xl bg-[#1F1F1F]"
          >
            <button
              onClick={() => setExpanded(isOpen ? null : sub.id)}
              className="flex w-full items-center justify-between p-3 text-left"
            >
              <div className="flex items-center gap-3">
                <div className="flex h-7 w-7 items-center justify-center rounded-full bg-[#A855F7]/15 text-xs font-medium text-[#A855F7]">
                  W{sub.agentId}
                </div>
                <div>
                  <p className="text-xs font-medium text-white/65">
                    Agent #{sub.agentId}
                  </p>
                  <p className="text-xs text-white/25">
                    {sub.agentAddress
                      ? shortenAddress(sub.agentAddress)
                      : agent
                        ? shortenAddress(agent.agentAddress)
                        : "Unknown"}
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                {evUrl && (
                  <a
                    href={evUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    onClick={(e) => e.stopPropagation()}
                    className="text-xs text-[#A855F7] hover:text-[#C084FC]"
                  >
                    Evidence
                  </a>
                )}
                <span className="text-xs text-white/25">
                  {isOpen ? "▲" : "▼"}
                </span>
              </div>
            </button>

            {isOpen && (
              <div className="border-t border-white/[0.06] p-3">
                <div className="mb-2 text-xs text-white/25">
                  <span className="font-mono">
                    Hash: {sub.dataHash.slice(0, 18)}...
                  </span>
                </div>
                {evUrl && <EvidenceViewer url={evUrl} />}
                {sub.scoreVectors && sub.scoreVectors.length > 0 && (
                  <div className="mt-3 text-xs text-white/25">
                    {sub.scoreVectors.length} score vector
                    {sub.scoreVectors.length !== 1 ? "s" : ""} received
                  </div>
                )}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
