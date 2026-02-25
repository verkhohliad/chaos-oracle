"use client";

import { useState } from "react";
import Link from "next/link";
import { useAgents } from "@/hooks/useAgents";
import { roleLabel } from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";
import { Skeleton } from "@/components/ui/Skeleton";
import { ReputationBadge } from "@/components/ui/ReputationBadge";

type Filter = "all" | "worker" | "verifier";

export default function AgentsPage() {
  const [filter, setFilter] = useState<Filter>("all");
  const { data: agents, isLoading, error } = useAgents();

  const filtered = agents?.filter((a) => {
    if (filter === "worker") return a.role === 1;
    if (filter === "verifier") return a.role === 2;
    return true;
  });

  return (
    <main className="mx-auto max-w-4xl px-6 py-10">
      <div className="mb-8">
        <h1 className="text-2xl font-semibold tracking-tight text-white">
          AI Agents
        </h1>
        <p className="mt-2 text-sm text-white/[0.38]">
          Workers and verifiers participating in prediction market settlement
        </p>
      </div>

      {/* Filter tabs */}
      <div className="mb-6 flex gap-2">
        {(["all", "worker", "verifier"] as Filter[]).map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors ${
              filter === f
                ? "bg-white/[0.08] text-white"
                : "text-white/[0.38] hover:text-white/65"
            }`}
          >
            {f === "all" ? "All" : f === "worker" ? "Workers" : "Verifiers"}
          </button>
        ))}
      </div>

      {isLoading && (
        <div className="space-y-3">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-16 w-full" />
          ))}
        </div>
      )}

      {error && (
        <div className="rounded-2xl bg-[#FF593C]/10 p-6 text-center text-sm text-[#FF593C]">
          Failed to load agents
        </div>
      )}

      {filtered && filtered.length === 0 && (
        <div className="rounded-2xl bg-[#131313] p-8 text-center text-sm text-white/25">
          No agents found
        </div>
      )}

      {filtered && filtered.length > 0 && (
        <div className="space-y-2">
          {filtered.map((agent) => (
            <Link
              key={agent.agentAddress}
              href={`/agents/${agent.agentAddress}`}
            >
              <div className="group flex items-center justify-between rounded-2xl bg-[#131313] p-4 transition-all duration-200 hover:bg-[#1B1B1B]">
                <div className="flex items-center gap-4">
                  <div
                    className={`flex h-9 w-9 items-center justify-center rounded-full text-xs font-semibold ${
                      agent.role === 1
                        ? "bg-[#A855F7]/15 text-[#A855F7]"
                        : "bg-[#FFBF17]/15 text-[#FFBF17]"
                    }`}
                  >
                    {agent.role === 1 ? "W" : "V"}
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium text-white/65">
                        Agent #{agent.agentId}
                      </span>
                      <span
                        className={`rounded-full px-2 py-0.5 text-[10px] font-medium ${
                          agent.role === 1
                            ? "bg-[#A855F7]/10 text-[#A855F7]"
                            : "bg-[#FFBF17]/10 text-[#FFBF17]"
                        }`}
                      >
                        {roleLabel(agent.role)}
                      </span>
                      <ReputationBadge agentId={agent.agentId} />
                    </div>
                    <ExplorerLink
                      type="address"
                      hash={agent.agentAddress}
                      className="text-xs"
                    />
                  </div>
                </div>
                <div className="text-right text-xs text-white/25">
                  <span>{agent.studioCount} studio{agent.studioCount !== 1 ? "s" : ""}</span>
                </div>
              </div>
            </Link>
          ))}
        </div>
      )}
    </main>
  );
}
