"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchGraphQL } from "./useGraphQL";
import { AGENT_DETAIL_QUERY } from "@/lib/queries";
import type { StudioAgent, WorkSubmission, ScoreVector } from "@/types";

interface AgentDetailResponse {
  StudioAgent: StudioAgent[];
  WorkSubmission: WorkSubmission[];
  ScoreVector: ScoreVector[];
}

export function useAgentDetail(agentAddress: string) {
  return useQuery({
    queryKey: ["agentDetail", agentAddress],
    queryFn: () =>
      fetchGraphQL<AgentDetailResponse>(AGENT_DETAIL_QUERY, {
        agentAddress: agentAddress.toLowerCase(),
      }),
    enabled: !!agentAddress,
  });
}
