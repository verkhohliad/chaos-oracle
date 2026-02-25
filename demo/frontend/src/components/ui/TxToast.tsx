"use client";

import { useTxToastStore, type TxToast } from "@/hooks/useTxToast";
import { explorerUrl } from "@/lib/utils";

function ToastItem({ toast }: { toast: TxToast }) {
  const { removeToast } = useTxToastStore();

  const bgClass =
    toast.status === "success"
      ? "border-[#21C95E]/20 bg-[#21C95E]/5"
      : toast.status === "error"
        ? "border-[#FF593C]/20 bg-[#FF593C]/5"
        : "border-[#A855F7]/20 bg-[#A855F7]/5";

  const iconColor =
    toast.status === "success"
      ? "text-[#21C95E]"
      : toast.status === "error"
        ? "text-[#FF593C]"
        : "text-[#A855F7]";

  return (
    <div
      className={`pointer-events-auto flex w-80 items-start gap-3 rounded-xl border p-3 shadow-lg backdrop-blur-xl transition-all duration-300 ${bgClass}`}
    >
      {/* Icon */}
      <div className={`mt-0.5 flex-shrink-0 text-sm ${iconColor}`}>
        {toast.status === "pending" && (
          <span className="inline-block animate-spin">&#9696;</span>
        )}
        {toast.status === "success" && <span>&#10003;</span>}
        {toast.status === "error" && <span>&#10007;</span>}
      </div>

      {/* Content */}
      <div className="min-w-0 flex-1">
        <p className="text-xs font-medium text-white/65">{toast.title}</p>
        <p className="mt-0.5 text-[10px] text-white/[0.38]">{toast.message}</p>
        {toast.hash && (
          <a
            href={explorerUrl("tx", toast.hash)}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-1 inline-block text-[10px] text-[#A855F7] hover:text-[#C084FC]"
          >
            View on Etherscan ↗
          </a>
        )}
      </div>

      {/* Dismiss */}
      <button
        onClick={() => removeToast(toast.id)}
        className="flex-shrink-0 text-xs text-white/25 hover:text-white/65"
      >
        &#10005;
      </button>
    </div>
  );
}

export function ToastContainer() {
  const { toasts } = useTxToastStore();

  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-6 right-6 z-[100] flex flex-col gap-2">
      {toasts.map((toast) => (
        <ToastItem key={toast.id} toast={toast} />
      ))}
    </div>
  );
}
