"use client";

import { create } from "zustand";
import { explorerUrl } from "@/lib/utils";

export interface TxToast {
  id: string;
  status: "pending" | "success" | "error";
  title: string;
  hash?: string;
  message?: string;
}

interface TxToastStore {
  toasts: TxToast[];
  addToast: (toast: Omit<TxToast, "id">) => string;
  updateToast: (id: string, update: Partial<TxToast>) => void;
  removeToast: (id: string) => void;
}

let counter = 0;

export const useTxToastStore = create<TxToastStore>((set) => ({
  toasts: [],
  addToast: (toast) => {
    const id = `toast-${++counter}`;
    set((state) => ({
      toasts: [...state.toasts, { ...toast, id }],
    }));
    // Auto-dismiss success after 8s
    if (toast.status === "success") {
      setTimeout(() => {
        set((state) => ({
          toasts: state.toasts.filter((t) => t.id !== id),
        }));
      }, 8000);
    }
    return id;
  },
  updateToast: (id, update) => {
    set((state) => ({
      toasts: state.toasts.map((t) =>
        t.id === id ? { ...t, ...update } : t
      ),
    }));
    // Auto-dismiss on success
    if (update.status === "success") {
      setTimeout(() => {
        set((state) => ({
          toasts: state.toasts.filter((t) => t.id !== id),
        }));
      }, 8000);
    }
  },
  removeToast: (id) => {
    set((state) => ({
      toasts: state.toasts.filter((t) => t.id !== id),
    }));
  },
}));

/**
 * Helper to create a toast for a transaction lifecycle.
 * Returns functions to update the toast on confirm/error.
 */
export function txToast(title: string, hash?: string) {
  const store = useTxToastStore.getState();
  const id = store.addToast({
    status: "pending",
    title,
    hash,
    message: "Transaction submitted...",
  });

  return {
    id,
    confirmed: (hash?: string) => {
      store.updateToast(id, {
        status: "success",
        hash,
        message: "Transaction confirmed!",
      });
    },
    failed: (error: string) => {
      store.updateToast(id, {
        status: "error",
        message: error,
      });
    },
  };
}
