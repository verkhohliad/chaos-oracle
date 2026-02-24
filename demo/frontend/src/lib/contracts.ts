export const MARKET_ADDRESS = (process.env.NEXT_PUBLIC_MARKET_ADDRESS ??
  "0x64A52A8ce57291cA701F18376f26E224F7E2AEcb") as `0x${string}`;

export const MARKET_ABI = [
  {
    type: "function",
    name: "placeBet",
    inputs: [
      { name: "_marketId", type: "uint256" },
      { name: "_option", type: "uint8" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "claimWinnings",
    inputs: [{ name: "_marketId", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "getMarket",
    inputs: [{ name: "_marketId", type: "uint256" }],
    outputs: [
      { name: "creator", type: "address" },
      { name: "_question", type: "string" },
      { name: "deadline", type: "uint256" },
      { name: "yesPool", type: "uint256" },
      { name: "noPool", type: "uint256" },
      { name: "outcome", type: "uint8" },
      { name: "settled", type: "bool" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getUserBet",
    inputs: [
      { name: "_marketId", type: "uint256" },
      { name: "_user", type: "address" },
      { name: "_option", type: "uint8" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;
