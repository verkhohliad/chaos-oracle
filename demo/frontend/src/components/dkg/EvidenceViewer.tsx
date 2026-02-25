"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { EvidencePayload } from "@/types";

interface EvidenceResponse extends EvidencePayload {
  _cid?: string;
  _url?: string;
}

async function fetchEvidence(
  dataHash: string,
  studioAddress: string
): Promise<EvidenceResponse> {
  const res = await fetch(
    `/api/evidence/${dataHash}?studio=${studioAddress}`
  );
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `Failed to fetch evidence (${res.status})`);
  }
  return res.json();
}

export function EvidenceViewer({
  dataHash,
  studioAddress,
}: {
  dataHash: string;
  studioAddress: string;
}) {
  const [showRaw, setShowRaw] = useState(false);

  const { data, isLoading, error } = useQuery({
    queryKey: ["evidence", dataHash, studioAddress],
    queryFn: () => fetchEvidence(dataHash, studioAddress),
    retry: 1,
    staleTime: Infinity,
  });

  if (isLoading) {
    return (
      <div className="animate-pulse rounded-xl bg-[#1F1F1F] p-3">
        <div className="h-3 w-1/2 rounded bg-white/[0.06]" />
      </div>
    );
  }

  if (error || !data) {
    return (
      <div className="rounded-xl bg-[#FF593C]/10 p-3 text-xs text-[#FF593C]">
        {error instanceof Error ? error.message : "Failed to load evidence"}
      </div>
    );
  }

  return (
    <div className="space-y-2 text-xs">
      {/* Toggle bar */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          {/* Outcome + Confidence */}
          <span
            className={`rounded-full px-2 py-0.5 font-medium ${
              (data.outcome_index ?? data.outcome) === 0
                ? "bg-[#21C95E]/15 text-[#21C95E]"
                : "bg-[#FF593C]/15 text-[#FF593C]"
            }`}
          >
            {(data.outcome_index ?? data.outcome) === 0 ? "Yes" : "No"}
          </span>
          {data.confidence != null && (
            <span className="text-white/[0.38]">
              {Math.round(data.confidence * 100)}% confidence
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {data._cid && (
            <a
              href={data._url ?? `https://arweave.net/${data._cid}`}
              target="_blank"
              rel="noopener noreferrer"
              className="text-[#A855F7] hover:text-[#C084FC]"
            >
              {data._cid.startsWith("Qm") || data._cid.startsWith("bafy")
                ? "IPFS"
                : "Arweave"}{" "}
              ↗
            </a>
          )}
          <button
            onClick={() => setShowRaw(!showRaw)}
            className={`rounded-lg px-2 py-0.5 transition-colors ${
              showRaw
                ? "bg-[#A855F7]/15 text-[#A855F7]"
                : "bg-white/[0.06] text-white/[0.38] hover:text-white/65"
            }`}
          >
            {showRaw ? "Formatted" : "Raw JSON"}
          </button>
        </div>
      </div>

      {showRaw ? (
        /* Raw JSON view */
        <pre className="max-h-96 overflow-auto rounded-xl bg-[#0a0a0a] p-3 font-mono text-[10px] leading-relaxed text-white/65">
          {JSON.stringify(data, null, 2)}
        </pre>
      ) : (
        /* Formatted view */
        <>
          {/* Reasoning */}
          {data.reasoning && (
            <div>
              <p className="mb-1 font-medium text-white/[0.38]">Reasoning</p>
              <p className="whitespace-pre-wrap text-white/65 leading-relaxed">
                {data.reasoning}
              </p>
            </div>
          )}

          {/* Sources */}
          {data.sources && data.sources.length > 0 && (
            <div>
              <p className="mb-1 font-medium text-white/[0.38]">Sources</p>
              <ul className="list-disc pl-4 space-y-0.5">
                {data.sources.map((src, i) => (
                  <li key={i} className="text-white/25 break-all">
                    {typeof src === "string" ? (
                      <a
                        href={src}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-[#A855F7] hover:text-[#C084FC]"
                      >
                        {src}
                      </a>
                    ) : (
                      <a
                        href={src.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-[#A855F7] hover:text-[#C084FC]"
                      >
                        {src.title || src.url}
                      </a>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {/* Search Queries */}
          {data.web_search_queries && data.web_search_queries.length > 0 && (
            <div>
              <p className="mb-1 font-medium text-white/[0.38]">
                Search Queries
              </p>
              <div className="flex flex-wrap gap-1">
                {data.web_search_queries.map((q, i) => (
                  <span
                    key={i}
                    className="rounded-lg bg-[#1F1F1F] px-2 py-0.5 text-white/[0.38]"
                  >
                    {q}
                  </span>
                ))}
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}
