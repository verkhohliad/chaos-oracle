import { NextResponse } from "next/server";

const GATEWAY_URL =
  process.env.GATEWAY_URL || "http://localhost:3000";

/**
 * Proxy to ChaosChain Gateway API.
 * GET /api/gateway/workflows?studio=0x...&type=WorkSubmission
 * GET /api/gateway/health
 * etc.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ path: string[] }> }
) {
  const { path } = await params;
  const { searchParams } = new URL(request.url);
  const gatewayPath = path.join("/");
  const qs = searchParams.toString();
  const url = `${GATEWAY_URL}/${gatewayPath}${qs ? `?${qs}` : ""}`;

  try {
    const res = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(15000),
    });

    if (!res.ok) {
      return NextResponse.json(
        { error: `Gateway returned ${res.status}` },
        { status: res.status }
      );
    }

    const data = await res.json();
    return NextResponse.json(data);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("Gateway proxy error:", message);
    return NextResponse.json(
      { error: message },
      { status: 502 }
    );
  }
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ path: string[] }> }
) {
  const { path } = await params;
  const gatewayPath = path.join("/");
  const body = await request.json();
  const url = `${GATEWAY_URL}/${gatewayPath}`;

  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15000),
    });

    if (!res.ok) {
      return NextResponse.json(
        { error: `Gateway returned ${res.status}` },
        { status: res.status }
      );
    }

    const data = await res.json();
    return NextResponse.json(data);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("Gateway proxy error:", message);
    return NextResponse.json(
      { error: message },
      { status: 502 }
    );
  }
}
