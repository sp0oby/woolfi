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
  {
    type: "function",
    name: "breakStatus",
    stateMutability: "view",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [
      {name: "broken", type: "bool"},
      {name: "confirmed", type: "bool"},
      {name: "detectedAt", type: "uint256"},
      {name: "confirmReadyAt", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "confirmStructuralBreak",
    stateMutability: "nonpayable",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [],
  },
  {
    type: "function",
    name: "clearRecoveredBreak",
    stateMutability: "nonpayable",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [],
  },
  {
    type: "event",
    name: "StructuralBreakTriggered",
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "driftBps", type: "int256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "StructuralBreakConfirmed",
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "driftBps", type: "int256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "StructuralBreakCleared",
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "driftBps", type: "int256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "StructuralBreakRecovered",
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "driftBps", type: "int256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "StructuralBreakResolved",
    inputs: [{name: "id", type: "bytes32", indexed: true}],
  },
  {
    type: "event",
    name: "DrawdownFailed",
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "vault", type: "address", indexed: false},
      {name: "reason", type: "bytes", indexed: false},
    ],
  },
  {
    type: "event",
    name: "BreakConfirmSecondsSet",
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "confirmSeconds", type: "uint32", indexed: false},
    ],
  },
  {type: "error", name: "OutOfBand", inputs: []},
  {type: "error", name: "MarketClosed", inputs: []},
  {type: "error", name: "NotStructurallyBroken", inputs: []},
  {type: "error", name: "AdversarialSwapDuringBreak", inputs: []},
  {type: "error", name: "StructuralBreakActive", inputs: []},
  {
    type: "error",
    name: "StabilizationActive",
    inputs: [
      {name: "sessionStart", type: "uint256"},
      {name: "endsAt", type: "uint256"},
    ],
  },
  {
    type: "error",
    name: "OracleTimestampSkew",
    inputs: [
      {name: "updatedAt0", type: "uint256"},
      {name: "updatedAt1", type: "uint256"},
      {name: "maxSkew", type: "uint32"},
    ],
  },
  {
    type: "error",
    name: "SwapWouldBreakPool",
    inputs: [
      {name: "preDriftBps", type: "int256"},
      {name: "postDriftBps", type: "int256"},
    ],
  },
  {type: "error", name: "BreakConfirmationPending", inputs: [{name: "readyAt", type: "uint256"}]},
  {type: "error", name: "BreakAlreadyConfirmed", inputs: []},
  {type: "error", name: "BreakNotConfirmed", inputs: []},
] as const;
