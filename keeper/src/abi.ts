export const DYNAMIC_FEE = 0x800000;

export const hookAbi = [
  {
    type: "function",
    name: "checkStructuralBreak",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "confirmStructuralBreak",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "clearRecoveredBreak",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
    ],
    outputs: [],
  },
  {type: "error", name: "NotStructurallyBroken", inputs: []},
  {type: "error", name: "BreakConfirmationPending", inputs: [{name: "readyAt", type: "uint256"}]},
  {type: "error", name: "BreakAlreadyConfirmed", inputs: []},
  {type: "error", name: "BreakNotConfirmed", inputs: []},
  {type: "error", name: "MarketClosed", inputs: []},
  {type: "error", name: "OutOfBand", inputs: []},
  {
    type: "error",
    name: "StabilizationActive",
    inputs: [{name: "sessionStart", type: "uint256"}, {name: "endsAt", type: "uint256"}],
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
] as const;

export const keeperAbi = [
  {
    type: "function",
    name: "keep",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
    ],
    outputs: [],
  },
] as const;
