export const DYNAMIC_FEE = 0x800000;

const poolKeyTuple = {
  name: "key",
  type: "tuple",
  components: [
    {name: "currency0", type: "address"},
    {name: "currency1", type: "address"},
    {name: "fee", type: "uint24"},
    {name: "tickSpacing", type: "int24"},
    {name: "hooks", type: "address"},
  ],
} as const;

export const hookAbi = [
  {type: "function", name: "currentDrift", stateMutability: "view", inputs: [poolKeyTuple], outputs: [{type: "int256"}]},
] as const;

export const oracleAbi = [
  {type: "function", name: "getPrice", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;

export const erc20Abi = [
  {type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{type: "uint8"}]},
] as const;

export const v3FactoryAbi = [
  {
    type: "function",
    name: "getPool",
    stateMutability: "view",
    inputs: [{type: "address"}, {type: "address"}, {type: "uint24"}],
    outputs: [{type: "address"}],
  },
] as const;

export const v3PoolAbi = [
  {type: "function", name: "liquidity", stateMutability: "view", inputs: [], outputs: [{type: "uint128"}]},
] as const;

export const quoterV2Abi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {name: "tokenIn", type: "address"},
          {name: "tokenOut", type: "address"},
          {name: "amountIn", type: "uint256"},
          {name: "fee", type: "uint24"},
          {name: "sqrtPriceLimitX96", type: "uint160"},
        ],
      },
    ],
    outputs: [
      {name: "amountOut", type: "uint256"},
      {name: "sqrtPriceX96After", type: "uint160"},
      {name: "initializedTicksCrossed", type: "uint32"},
      {name: "gasEstimate", type: "uint256"},
    ],
  },
] as const;

export const executorAbi = [
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          {...poolKeyTuple, name: "woolfiKey"},
          {name: "zeroForOne", type: "bool"},
          {name: "amountIn", type: "uint256"},
          {name: "v3Fee", type: "uint24"},
          {name: "minProfit", type: "uint256"},
          {name: "profitToken", type: "address"},
          {name: "recipient", type: "address"},
          {name: "deadline", type: "uint256"},
        ],
      },
    ],
    outputs: [{name: "profit", type: "uint256"}],
  },
] as const;
