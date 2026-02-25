"use client";

import { useReadContracts } from "wagmi";
import type { Market } from "@/types";
import { formatEth, outcomeLabel, roleLabel } from "@/lib/utils";
import { ExplorerLink } from "@/components/ui/ExplorerLink";
import { ReputationBadge } from "@/components/ui/ReputationBadge";
import { STUDIO_PROXY_ABI } from "@/lib/contracts";

export function SettlementBreakdown({ market }: { market: Market }) {
  if (!market.settled) return null;

  const yesPool = BigInt(market.yesPool);
  const noPool = BigInt(market.noPool);
  const totalPool = yesPool + noPool;
  const winningOption = market.outcome ?? 0;
  // outcome 0 = Yes wins (yesPool), outcome 1 = No wins (noPool)
  const winPool = winningOption === 0 ? yesPool : noPool;
  const losePool = winningOption === 0 ? noPool : yesPool;

  const claims = market.claims ?? [];
  const totalClaimed = claims.reduce(
    (sum, c) => sum + BigInt(c.amount),
    0n
  );

  const agents = market.studio?.agents ?? [];
  const workers = agents.filter((a) => a.role === 1);
  const verifiers = agents.filter((a) => a.role === 2);
  const submissions = market.studio?.workSubmissions ?? [];

  const studioAddress = market.studio?.id;

  // Read withdrawable balances for all agents
  const balanceCalls = agents.map((agent) => ({
    address: studioAddress as `0x${string}`,
    abi: STUDIO_PROXY_ABI,
    functionName: "getWithdrawableBalance" as const,
    args: [agent.agentAddress as `0x${string}`],
  }));

  const { data: balances } = useReadContracts({
    contracts: balanceCalls,
    query: {
      enabled: !!studioAddress && agents.length > 0,
      staleTime: 30_000,
    },
  });

  const getBalance = (index: number): string | null => {
    if (!balances || !balances[index] || balances[index].status !== "success") return null;
    const val = balances[index].result as bigint;
    if (val === 0n) return null;
    return formatEth(val.toString());
  };

  return (
    <div className="rounded-2xl bg-[#131313] p-6 space-y-5">
      <h2 className="text-sm font-medium text-white/65">
        Settlement Breakdown
      </h2>

      {/* Pool Summary */}
      <div className="grid grid-cols-3 gap-3">
        <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
          <p className="text-[10px] text-white/[0.38]">Yes Pool</p>
          <p className="mt-1 text-sm font-medium text-[#21C95E]">
            {formatEth(market.yesPool)} ETH
          </p>
        </div>
        <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
          <p className="text-[10px] text-white/[0.38]">No Pool</p>
          <p className="mt-1 text-sm font-medium text-[#FF593C]">
            {formatEth(market.noPool)} ETH
          </p>
        </div>
        <div className="rounded-xl bg-[#1F1F1F] p-3 text-center">
          <p className="text-[10px] text-white/[0.38]">Total</p>
          <p className="mt-1 text-sm font-medium text-white/65">
            {formatEth(totalPool.toString())} ETH
          </p>
        </div>
      </div>

      {/* Winning outcome */}
      <div className="rounded-xl bg-[#21C95E]/5 p-3 flex items-center justify-between">
        <div>
          <p className="text-[10px] text-white/[0.38]">Winning Side</p>
          <p className="mt-0.5 text-sm font-medium text-[#21C95E]">
            {outcomeLabel(winningOption, market.options)}
          </p>
        </div>
        <div className="text-right">
          <p className="text-[10px] text-white/[0.38]">Win Pool / Lose Pool</p>
          <p className="mt-0.5 text-xs text-white/65">
            {formatEth(winPool.toString())} / {formatEth(losePool.toString())} ETH
          </p>
        </div>
      </div>

      {/* Settlement reward */}
      <div className="rounded-xl bg-[#A855F7]/5 p-3">
        <p className="text-[10px] text-white/[0.38]">
          Settlement Reward (10% of creation ETH)
        </p>
        <p className="mt-0.5 text-sm font-medium text-[#A855F7]">
          {formatEth(market.settlementReward)} ETH
        </p>
        <p className="mt-1 text-[10px] text-white/[0.12]">
          Budget split: 85% worker / 10% validator / 5% orchestrator
        </p>
      </div>

      {/* Bettor claims */}
      {claims.length > 0 && (
        <div>
          <p className="mb-2 text-xs font-medium text-white/[0.38]">
            Bettor Payouts ({claims.length})
          </p>
          <div className="space-y-1">
            {claims.map((claim) => (
              <div
                key={claim.id}
                className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-3 py-2"
              >
                <ExplorerLink
                  type="address"
                  hash={claim.claimer}
                  className="text-xs"
                />
                <span className="text-xs font-mono text-[#21C95E]">
                  +{formatEth(claim.amount)} ETH
                </span>
              </div>
            ))}
          </div>
          <div className="mt-2 flex justify-between text-[10px] text-white/25">
            <span>Total claimed: {formatEth(totalClaimed.toString())} ETH</span>
            <span>Available: {formatEth(totalPool.toString())} ETH</span>
          </div>
        </div>
      )}

      {/* Workers with submissions */}
      {workers.length > 0 && (
        <div>
          <p className="mb-2 text-xs font-medium text-white/[0.38]">
            Workers ({workers.length})
          </p>
          <div className="space-y-1">
            {workers.map((agent) => {
              const agentIndex = agents.indexOf(agent);
              const balance = getBalance(agentIndex);
              const sub = submissions.find((s) => s.agentId === agent.agentId);
              return (
                <div
                  key={agent.id}
                  className="rounded-xl bg-[#1F1F1F] px-3 py-2"
                >
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <span className="text-xs font-medium text-[#A855F7]">
                        W{agent.agentId}
                      </span>
                      <ExplorerLink
                        type="address"
                        hash={agent.agentAddress}
                        className="text-xs"
                      />
                      <ReputationBadge agentId={agent.agentId} />
                    </div>
                    <div className="flex items-center gap-3 text-xs">
                      <span className="font-mono text-white/[0.38]">
                        Stake: {formatEth(agent.stake)}
                      </span>
                      {balance && (
                        <span className="font-mono text-[#21C95E]">
                          +{balance} ETH
                        </span>
                      )}
                    </div>
                  </div>
                  {sub && (
                    <div className="mt-1 text-[10px] text-white/25">
                      <span className="font-mono">{sub.dataHash.slice(0, 18)}...</span>
                      {sub.scoreVectors && sub.scoreVectors.length > 0 && (
                        <span className="ml-2">
                          {sub.scoreVectors.length} score{sub.scoreVectors.length !== 1 ? "s" : ""} received
                        </span>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Verifiers */}
      {verifiers.length > 0 && (
        <div>
          <p className="mb-2 text-xs font-medium text-white/[0.38]">
            Verifiers ({verifiers.length})
          </p>
          <div className="space-y-1">
            {verifiers.map((agent) => {
              const agentIndex = agents.indexOf(agent);
              const balance = getBalance(agentIndex);
              return (
                <div
                  key={agent.id}
                  className="flex items-center justify-between rounded-xl bg-[#1F1F1F] px-3 py-2"
                >
                  <div className="flex items-center gap-2">
                    <span className="text-xs font-medium text-[#FFBF17]">
                      V{agent.agentId}
                    </span>
                    <ExplorerLink
                      type="address"
                      hash={agent.agentAddress}
                      className="text-xs"
                    />
                    <ReputationBadge agentId={agent.agentId} />
                  </div>
                  <div className="flex items-center gap-3 text-xs">
                    <span className="font-mono text-white/[0.38]">
                      Stake: {formatEth(agent.stake)}
                    </span>
                    {balance && (
                      <span className="font-mono text-[#21C95E]">
                        +{balance} ETH
                      </span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
