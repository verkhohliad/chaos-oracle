"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchGraphQL } from "./useGraphQL";
import { AGENTS_QUERY } from "@/lib/queries";
import type { StudioAgent, AgentSummary } from "@/types";

interface AgentsResponse {
  StudioAgent: StudioAgent[];
}

export function useAgents(limit = 200) {
  return useQuery({
    queryKey: ["agents", limit],
    queryFn: () =>
      fetchGraphQL<AgentsResponse>(AGENTS_QUERY, { limit, offset: 0 }),
    select: (data) => {
      // Aggregate by agentAddress
      const map = new Map<string, AgentSummary>();
      for (const agent of data.StudioAgent) {
        const existing = map.get(agent.agentAddress);
        if (existing) {
          existing.studioCount += 1;
        } else {
          map.set(agent.agentAddress, {
            agentAddress: agent.agentAddress,
            agentId: agent.agentId,
            role: agent.role,
            studioCount: 1,
            submissionCount: 0,
            scoreCount: 0,
          });
        }
      }
      return Array.from(map.values());
    },
  });
}
