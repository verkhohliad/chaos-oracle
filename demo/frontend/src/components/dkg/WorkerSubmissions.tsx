"use client";

import { useState } from "react";
import type { WorkSubmission, StudioAgent } from "@/types";
import { shortenAddress } from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";
import { EvidenceViewer } from "./EvidenceViewer";

export function WorkerSubmissions({
  submissions,
  agents,
  studioAddress,
}: {
  submissions: WorkSubmission[];
  agents: StudioAgent[];
  studioAddress: string;
}) {
  const [expanded, setExpanded] = useState<string | null>(null);

  const agentMap = new Map(
    agents.map((a) => [a.agentId, a])
  );

  return (
    <div className="space-y-3">
      {submissions.map((sub) => {
        const agent = agentMap.get(sub.agentId);
        const isOpen = expanded === sub.id;
        const agentAddr = sub.agentAddress ?? agent?.agentAddress;

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
                  {agentAddr ? (
                    <ExplorerLink
                      type="address"
                      hash={agentAddr}
                      label={shortenAddress(agentAddr)}
                      className="text-xs"
                    />
                  ) : (
                    <p className="text-xs text-white/25">Unknown</p>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-2">
                {sub.scoreVectors && sub.scoreVectors.length > 0 && (
                  <span className="text-xs text-white/25">
                    {sub.scoreVectors.length} score{sub.scoreVectors.length !== 1 ? "s" : ""}
                  </span>
                )}
                <span className="text-xs text-white/25">
                  {isOpen ? "▲" : "▼"}
                </span>
              </div>
            </button>

            {isOpen && (
              <div className="border-t border-white/[0.06] p-3 space-y-3">
                {/* Data hash */}
                <div className="text-xs text-white/25">
                  <span className="font-mono">
                    Hash: {sub.dataHash.slice(0, 18)}...
                  </span>
                </div>

                {/* Evidence viewer via API route */}
                <EvidenceViewer
                  dataHash={sub.dataHash}
                  studioAddress={studioAddress}
                />

                {/* Thread root */}
                {sub.threadRoot && sub.threadRoot !== "0x" + "0".repeat(64) && (
                  <div className="text-xs text-white/25">
                    Thread root:{" "}
                    <span className="font-mono">{sub.threadRoot.slice(0, 18)}...</span>
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
