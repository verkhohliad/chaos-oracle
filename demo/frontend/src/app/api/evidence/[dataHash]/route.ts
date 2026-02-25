import { NextResponse } from "next/server";
import { createPublicClient, http } from "viem";
import { sepolia } from "viem/chains";
import { STUDIO_PROXY_ABI } from "@/lib/contracts";

const SEPOLIA_RPC =
  process.env.SEPOLIA_RPC ??
  `https://eth-sepolia.g.alchemy.com/v2/${process.env.NEXT_PUBLIC_ALCHEMY_KEY ?? "demo"}`;

const GATEWAY_URL = process.env.GATEWAY_URL || "http://localhost:3000";
const IPFS_GATEWAY = process.env.IPFS_GATEWAY || "http://localhost:8080/ipfs/";

const client = createPublicClient({
  chain: sepolia,
  transport: http(SEPOLIA_RPC),
});

/**
 * Fetch evidence JSON from IPFS/Arweave using a CID.
 * Handles ar:// protocol prefix (Gateway stores as "ar://{txId}").
 * Routes to Arweave or IPFS gateways based on CID type.
 */
async function fetchFromCID(rawCid: string): Promise<Response | null> {
  let cid = rawCid;

  // Strip ar:// protocol prefix (Gateway stores CIDs as "ar://{txId}")
  if (cid.startsWith("ar://")) {
    cid = cid.slice(5);
  }

  // Determine CID type and build gateway list accordingly
  const isIPFS = cid.startsWith("Qm") || cid.startsWith("bafy");

  const gateways: string[] = isIPFS
    ? [
        `${IPFS_GATEWAY}${cid}`,
        `https://gateway.pinata.cloud/ipfs/${cid}`,
        `https://ipfs.io/ipfs/${cid}`,
      ]
    : [
        // Arweave CID (43-char base64url TX ID)
        `https://arweave.net/${cid}`,
      ];

  for (const url of gateways) {
    try {
      const res = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(10000),
      });
      if (res.ok) return res;
    } catch {
      // Try next gateway
    }
  }
  return null;
}

/**
 * GET /api/evidence/[dataHash]?studio=0x...
 *
 * 3-level fallback for resolving evidence:
 * 1. On-chain: StudioProxy.getEvidenceCID(dataHash)
 * 2. Gateway API: GET /workflows?studio={addr}&type=WorkSubmission
 * 3. Direct IPFS fetch if we find a CID anywhere
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ dataHash: string }> }
) {
  const { dataHash } = await params;
  const { searchParams } = new URL(request.url);
  const studioAddress = searchParams.get("studio");

  if (!studioAddress) {
    return NextResponse.json(
      { error: "Missing studio query parameter" },
      { status: 400 }
    );
  }

  let evidenceCID: string | null = null;

  // Level 1: Try on-chain getEvidenceCID
  try {
    const cid = await client.readContract({
      address: studioAddress as `0x${string}`,
      abi: STUDIO_PROXY_ABI,
      functionName: "getEvidenceCID",
      args: [dataHash as `0x${string}`],
    });
    if (cid && cid !== "") {
      evidenceCID = cid;
    }
  } catch (err) {
    console.log("On-chain getEvidenceCID failed (expected for single-agent):", err instanceof Error ? err.message : err);
  }

  // Level 2: Try Gateway API to find evidence CIDs
  if (!evidenceCID) {
    try {
      const gwRes = await fetch(
        `${GATEWAY_URL}/workflows?studio=${studioAddress}&type=WorkSubmission`,
        {
          headers: { Accept: "application/json" },
          signal: AbortSignal.timeout(10000),
        }
      );
      if (gwRes.ok) {
        const workflows = await gwRes.json();
        // Find the matching workflow by dataHash
        const items = Array.isArray(workflows) ? workflows : workflows.data ?? [];
        for (const wf of items) {
          const wfDataHash = wf.dataHash || wf.data_hash || wf.hash;
          const wfCID = wf.evidenceCID || wf.evidence_cid || wf.cid || wf.result?.cid;
          if (wfDataHash === dataHash && wfCID) {
            evidenceCID = wfCID;
            break;
          }
          // If no specific match, take the first CID we find
          if (!evidenceCID && wfCID) {
            evidenceCID = wfCID;
          }
        }
      }
    } catch (err) {
      console.log("Gateway query failed:", err instanceof Error ? err.message : err);
    }
  }

  if (!evidenceCID) {
    return NextResponse.json(
      { error: "No evidence CID found for this dataHash. Gateway may not be running." },
      { status: 404 }
    );
  }

  // Fetch evidence content from IPFS/Arweave
  try {
    const res = await fetchFromCID(evidenceCID);
    if (!res) {
      return NextResponse.json(
        { error: `Found CID ${evidenceCID} but failed to fetch from any gateway` },
        { status: 502 }
      );
    }

    const data = await res.json();
    // Build resolved URL based on CID type
    const cleanCid = evidenceCID.startsWith("ar://") ? evidenceCID.slice(5) : evidenceCID;
    const isIPFS = cleanCid.startsWith("Qm") || cleanCid.startsWith("bafy");
    const resolvedUrl = isIPFS
      ? `${IPFS_GATEWAY}${cleanCid}`
      : `https://arweave.net/${cleanCid}`;
    return NextResponse.json({ ...data, _cid: evidenceCID, _url: resolvedUrl });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("Evidence fetch error:", message);
    return NextResponse.json(
      { error: message },
      { status: 500 }
    );
  }
}
