"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import Link from "next/link";
import { usePathname } from "next/navigation";

const NAV_LINKS = [
  { href: "/", label: "Markets" },
  { href: "/create", label: "Create" },
  { href: "/agents", label: "Agents" },
] as const;

export function Header() {
  const pathname = usePathname();

  return (
    <header className="sticky top-0 z-50 border-b border-white/[0.06] bg-black/60 backdrop-blur-xl">
      <div className="mx-auto flex max-w-7xl items-center justify-between px-6 py-4">
        <div className="flex items-center gap-8">
          <Link
            href="/"
            className="flex items-center gap-2.5 text-lg font-semibold tracking-tight text-white transition-opacity hover:opacity-80"
          >
            <span className="text-2xl">&#128302;</span>
            <span>ChaosOracle</span>
          </Link>

          <nav className="hidden items-center gap-1 sm:flex">
            {NAV_LINKS.map(({ href, label }) => {
              const isActive =
                href === "/"
                  ? pathname === "/"
                  : pathname.startsWith(href);
              return (
                <Link
                  key={href}
                  href={href}
                  className={`rounded-lg px-3 py-1.5 text-sm transition-colors ${
                    isActive
                      ? "bg-white/[0.08] font-medium text-white"
                      : "text-white/[0.38] hover:text-white/65"
                  }`}
                >
                  {label}
                </Link>
              );
            })}
          </nav>
        </div>

        <ConnectButton showBalance={false} />
      </div>
    </header>
  );
}
