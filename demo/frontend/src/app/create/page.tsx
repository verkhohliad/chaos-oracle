"use client";

import { CreateMarketForm } from "@/components/market/CreateMarketForm";

export default function CreateMarketPage() {
  return (
    <main className="mx-auto max-w-xl px-6 py-10">
      <div className="mb-8">
        <h1 className="text-2xl font-semibold tracking-tight text-white">
          Create Market
        </h1>
        <p className="mt-2 text-sm text-white/[0.38]">
          Create a binary prediction market settled by AI consensus
        </p>
      </div>

      <div className="rounded-2xl bg-[#131313] p-6">
        <CreateMarketForm />
      </div>
    </main>
  );
}
