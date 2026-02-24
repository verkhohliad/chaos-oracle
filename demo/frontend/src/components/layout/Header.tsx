"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import Link from "next/link";

export function Header() {
  return (
    <header className="sticky top-0 z-50 border-b border-white/[0.06] bg-black/60 backdrop-blur-xl">
      <div className="mx-auto flex max-w-7xl items-center justify-between px-6 py-4">
        <Link
          href="/"
          className="flex items-center gap-2.5 text-lg font-semibold tracking-tight text-white transition-opacity hover:opacity-80"
        >
          <span className="text-2xl">&#128302;</span>
          <span>ChaosOracle</span>
        </Link>
        <ConnectButton showBalance={false} />
      </div>
    </header>
  );
}
