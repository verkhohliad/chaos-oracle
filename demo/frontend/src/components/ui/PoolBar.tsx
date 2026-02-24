import { formatEth } from "@/lib/utils";

export function PoolBar({
  yesPool,
  noPool,
}: {
  yesPool: string;
  noPool: string;
}) {
  const yes = BigInt(yesPool);
  const no = BigInt(noPool);
  const total = yes + no;
  const yesPct = total > 0n ? Number((yes * 100n) / total) : 50;
  const noPct = 100 - yesPct;

  return (
    <div>
      <div className="mb-1.5 flex justify-between text-xs">
        <span className="font-medium text-[#21C95E]">
          Yes {formatEth(yesPool)} ETH ({yesPct}%)
        </span>
        <span className="font-medium text-[#FF593C]">
          No {formatEth(noPool)} ETH ({noPct}%)
        </span>
      </div>
      <div className="flex h-2 overflow-hidden rounded-full bg-white/[0.06]">
        <div
          className="bg-[#21C95E] transition-all duration-300"
          style={{ width: `${yesPct}%` }}
        />
        <div
          className="bg-[#FF593C] transition-all duration-300"
          style={{ width: `${noPct}%` }}
        />
      </div>
    </div>
  );
}
