import Link from "next/link";
import { MarketGrid } from "@/components/market/MarketGrid";

export default function ExplorePage() {
  return (
    <main className="mx-auto max-w-6xl px-6 py-10">
      <div className="mb-10 flex items-start justify-between">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight text-white">
            Prediction Markets
          </h1>
          <p className="mt-2 text-sm text-white/[0.38]">
            AI-settled prediction markets powered by ChaosChain + Chainlink CRE
          </p>
        </div>
        <Link
          href="/create"
          className="rounded-xl bg-[#A855F7] px-4 py-2.5 text-sm font-medium text-white transition-all duration-200 hover:bg-[#C084FC]"
        >
          + Create Market
        </Link>
      </div>
      <MarketGrid />
    </main>
  );
}
