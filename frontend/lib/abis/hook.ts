import {poolKeyComponents} from "./poolKey";

export const hookAbi = [
  {
    type: "function",
    name: "currentDrift",
    stateMutability: "view",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [{name: "", type: "int256"}],
  },
  {
    type: "function",
    name: "poolConfig",
    stateMutability: "view",
    inputs: [{name: "id", type: "bytes32"}],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          {name: "oracle0", type: "address"},
          {name: "oracle1", type: "address"},
          {name: "marketHours", type: "address"},
          {name: "vault", type: "address"},
          {name: "cachedFairPriceWad", type: "uint256"},
          {name: "kScaled", type: "uint32"},
          {name: "stabilizationSeconds", type: "uint32"},
          {name: "maxOracleSkew", type: "uint32"},
          {name: "baseFeeBps", type: "uint16"},
          {name: "toleranceBps", type: "uint16"},
          {name: "hardThresholdBps", type: "uint16"},
          {name: "drawdownBps", type: "uint16"},
          {name: "decimals0", type: "uint8"},
          {name: "decimals1", type: "uint8"},
          {name: "configured", type: "bool"},
          {name: "structuralBreak", type: "bool"},
        ],
      },
    ],
  },
  {
    type: "function",
    name: "poolSafetyStatus",
    stateMutability: "view",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [
      {name: "structurallyBroken", type: "bool"},
      {name: "cachedFairPriceWad", type: "uint256"},
      {name: "stabilizing", type: "bool"},
      {name: "oracleSkewed", type: "bool"},
    ],
  },
  {
    type: "function",
    name: "checkStructuralBreak",
    stateMutability: "nonpayable",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [],
  },
] as const;
