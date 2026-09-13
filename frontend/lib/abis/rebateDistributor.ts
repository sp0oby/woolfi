export const rebateDistributorAbi = [
  {
    type: "function",
    name: "claimable",
    stateMutability: "view",
    inputs: [
      {name: "account", type: "address"},
      {name: "token", type: "address"},
    ],
    outputs: [{name: "amount", type: "uint256"}],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [
      {name: "token", type: "address"},
      {name: "recipient", type: "address"},
    ],
    outputs: [{name: "amount", type: "uint256"}],
  },
] as const;
