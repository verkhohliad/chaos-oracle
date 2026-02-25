import { explorerUrl, shortenAddress } from "@/lib/utils";

export function ExplorerLink({
  type,
  hash,
  label,
  className = "",
}: {
  type: "tx" | "address" | "block";
  hash: string;
  label?: string;
  className?: string;
}) {
  if (!hash || hash === "0x" + "0".repeat(64)) return null;

  const displayLabel =
    label ?? (type === "tx" ? `${hash.slice(0, 10)}...` : shortenAddress(hash));

  return (
    <a
      href={explorerUrl(type, hash)}
      target="_blank"
      rel="noopener noreferrer"
      className={`inline-flex items-center gap-1 text-[#A855F7] hover:text-[#C084FC] transition-colors ${className}`}
    >
      <span>{displayLabel}</span>
      <svg
        width="10"
        height="10"
        viewBox="0 0 12 12"
        fill="none"
        className="opacity-50"
      >
        <path
          d="M3.5 1.5H1.5V10.5H10.5V8.5M7.5 1.5H10.5V4.5M10.5 1.5L5.5 6.5"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </a>
  );
}
