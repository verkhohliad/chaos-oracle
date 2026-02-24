import { NextResponse } from "next/server";

const INDEXER_URL =
  process.env.INDEXER_GRAPHQL_URL || "http://localhost:8080/v1/graphql";

export async function POST(request: Request) {
  const body = await request.json();

  const res = await fetch(INDEXER_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const data = await res.json();
  return NextResponse.json(data);
}
