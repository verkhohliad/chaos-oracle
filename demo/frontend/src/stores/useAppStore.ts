import { create } from "zustand";

interface AppState {
  selectedOption: number | null;
  betAmount: string;
  setSelectedOption: (option: number | null) => void;
  setBetAmount: (amount: string) => void;
  reset: () => void;
}

export const useAppStore = create<AppState>((set) => ({
  selectedOption: null,
  betAmount: "0.01",
  setSelectedOption: (option) => set({ selectedOption: option }),
  setBetAmount: (amount) => set({ betAmount: amount }),
  reset: () => set({ selectedOption: null, betAmount: "0.01" }),
}));
