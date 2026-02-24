export function Skeleton({ className = "" }: { className?: string }) {
  return (
    <div
      className={`animate-pulse rounded-2xl bg-white/[0.06] ${className}`}
    />
  );
}

export function MarketCardSkeleton() {
  return (
    <div className="rounded-2xl bg-[#131313] p-6">
      <Skeleton className="mb-3 h-5 w-3/4 rounded-xl" />
      <Skeleton className="mb-4 h-4 w-1/2 rounded-xl" />
      <Skeleton className="mb-3 h-3 w-full rounded-xl" />
      <div className="flex gap-3">
        <Skeleton className="h-9 flex-1 rounded-xl" />
        <Skeleton className="h-9 flex-1 rounded-xl" />
      </div>
    </div>
  );
}
