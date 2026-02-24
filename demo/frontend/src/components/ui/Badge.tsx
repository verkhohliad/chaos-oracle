import { statusColor, statusLabel } from "@/lib/utils";
import type { MarketStatus } from "@/types";

export function Badge({
  status,
  outcome,
  options,
}: {
  status: MarketStatus;
  outcome?: number | null;
  options?: string[];
}) {
  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${statusColor(status)}`}
    >
      {statusLabel(status, outcome, options)}
    </span>
  );
}
