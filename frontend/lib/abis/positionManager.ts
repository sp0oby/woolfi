import {poolKeyComponents} from "./poolKey";

export const pmAbi = [
  {
    type: "function",
    name: "totalShares",
    stateMutability: "view",
    inputs: [{name: "id", type: "uint256"}],
    outputs: [{name: "", type: "uint256"}],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [
      {name: "owner", type: "address"},
      {name: "id", type: "uint256"},
    ],
    outputs: [{name: "", type: "uint256"}],
  },
  {
    type: "function",
    name: "pendingFees",
    stateMutability: "view",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "account", type: "address"},
    ],
    outputs: [
      {name: "fee0", type: "uint256"},
      {name: "fee1", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "previewMint",
    stateMutability: "view",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "amount0Max", type: "uint256"},
      {name: "amount1Max", type: "uint256"},
    ],
    outputs: [{name: "shares", type: "uint128"}],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "amount0Max", type: "uint256"},
      {name: "amount1Max", type: "uint256"},
      {name: "to", type: "address"},
    ],
    outputs: [{name: "shares", type: "uint128"}],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "amount0Max", type: "uint256"},
      {name: "amount1Max", type: "uint256"},
      {name: "minShares", type: "uint128"},
      {name: "deadline", type: "uint256"},
      {name: "to", type: "address"},
    ],
    outputs: [{name: "shares", type: "uint128"}],
  },
  {
    type: "function",
    name: "burn",
    stateMutability: "nonpayable",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "shares", type: "uint128"},
      {name: "to", type: "address"},
    ],
    outputs: [
      {name: "amount0", type: "uint256"},
      {name: "amount1", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "collectFees",
    stateMutability: "nonpayable",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "to", type: "address"},
    ],
    outputs: [
      {name: "amount0", type: "uint256"},
      {name: "amount1", type: "uint256"},
    ],
  },
] as const;

/** PM events the dashboard reads via getLogs - for the 24h fee tally on PoolCard. */
export const pmEventsAbi = [
  {
    type: "event",
    name: "FeesRouted",
    inputs: [
      {indexed: true, name: "id", type: "uint256"},
      {indexed: false, name: "vault0", type: "uint256"},
      {indexed: false, name: "vault1", type: "uint256"},
      {indexed: false, name: "treasury0", type: "uint256"},
      {indexed: false, name: "treasury1", type: "uint256"},
    ],
    anonymous: false,
  },
] as const;
