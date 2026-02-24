import { MarketGrid } from "@/components/market/MarketGrid";

export default function ExplorePage() {
  return (
    <main className="mx-auto max-w-6xl px-6 py-10">
      <div className="mb-10">
        <h1 className="text-3xl font-semibold tracking-tight text-white">
          Prediction Markets
        </h1>
        <p className="mt-2 text-sm text-white/[0.38]">
          AI-settled prediction markets powered by ChaosChain + Chainlink CRE
        </p>
      </div>
      <MarketGrid />
    </main>
  );
}
