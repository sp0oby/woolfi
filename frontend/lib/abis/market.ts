export const oracleAbi = [
  {
    type: "function",
    name: "getPrice",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "priceWad", type: "uint256"}],
  },
] as const;

export const marketHoursAbi = [
  {
    type: "function",
    name: "isMarketOpen",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "bool"}],
  },
  {
    type: "function",
    name: "lastUpdate",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "uint64"}],
  },
  {
    type: "function",
    name: "currentSessionStart",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "uint256"}],
  },
] as const;
