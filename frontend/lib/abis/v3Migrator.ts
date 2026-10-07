import {poolKeyComponents} from "./poolKey";

/** WoolFiV3Migrator: stateless Uniswap v3 position -> full-range WoolFi LP migration. */
export const v3MigratorAbi = [
  {
    type: "function",
    name: "migrate",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          {name: "tokenId", type: "uint256"},
          {name: "woolfiKey", type: "tuple", components: poolKeyComponents},
          {name: "liquidity", type: "uint128"},
          {name: "amount0Min", type: "uint256"},
          {name: "amount1Min", type: "uint256"},
          {name: "minShares", type: "uint128"},
          {name: "deadline", type: "uint256"},
          {name: "recipient", type: "address"},
        ],
      },
    ],
    outputs: [{name: "shares", type: "uint128"}],
  },
  {
    type: "event",
    name: "Migrated",
    inputs: [
      {name: "owner", type: "address", indexed: true},
      {name: "tokenId", type: "uint256", indexed: true},
      {name: "recipient", type: "address", indexed: true},
      {name: "liquidityRemoved", type: "uint128", indexed: false},
      {name: "amount0", type: "uint256", indexed: false},
      {name: "amount1", type: "uint256", indexed: false},
      {name: "shares", type: "uint128", indexed: false},
      {name: "refund0", type: "uint256", indexed: false},
      {name: "refund1", type: "uint256", indexed: false},
    ],
  },
  {type: "error", name: "PairMismatch", inputs: []},
  {type: "error", name: "SingleSidedPosition", inputs: [{name: "amount0", type: "uint256"}, {name: "amount1", type: "uint256"}]},
  {type: "error", name: "NothingToMigrate", inputs: []},
  {type: "error", name: "NotPositionOwner", inputs: [{name: "caller", type: "address"}, {name: "owner", type: "address"}]},
  {type: "error", name: "LiquidityTooHigh", inputs: [{name: "requested", type: "uint128"}, {name: "available", type: "uint128"}]},
  {type: "error", name: "DeadlineExpired", inputs: [{name: "deadline", type: "uint256"}]},
] as const;

/** The subset of the Uniswap v3 NonfungiblePositionManager the migrate flow reads and calls. */
export const uniswapV3NpmAbi = [
  {type: "function", name: "balanceOf", stateMutability: "view", inputs: [{name: "owner", type: "address"}], outputs: [{name: "", type: "uint256"}]},
  {
    type: "function",
    name: "tokenOfOwnerByIndex",
    stateMutability: "view",
    inputs: [{name: "owner", type: "address"}, {name: "index", type: "uint256"}],
    outputs: [{name: "", type: "uint256"}],
  },
  {
    type: "function",
    name: "positions",
    stateMutability: "view",
    inputs: [{name: "tokenId", type: "uint256"}],
    outputs: [
      {name: "nonce", type: "uint96"},
      {name: "operator", type: "address"},
      {name: "token0", type: "address"},
      {name: "token1", type: "address"},
      {name: "fee", type: "uint24"},
      {name: "tickLower", type: "int24"},
      {name: "tickUpper", type: "int24"},
      {name: "liquidity", type: "uint128"},
      {name: "feeGrowthInside0LastX128", type: "uint256"},
      {name: "feeGrowthInside1LastX128", type: "uint256"},
      {name: "tokensOwed0", type: "uint128"},
      {name: "tokensOwed1", type: "uint128"},
    ],
  },
  {type: "function", name: "getApproved", stateMutability: "view", inputs: [{name: "tokenId", type: "uint256"}], outputs: [{name: "", type: "address"}]},
  {
    type: "function",
    name: "isApprovedForAll",
    stateMutability: "view",
    inputs: [{name: "owner", type: "address"}, {name: "operator", type: "address"}],
    outputs: [{name: "", type: "bool"}],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{name: "to", type: "address"}, {name: "tokenId", type: "uint256"}],
    outputs: [],
  },
  {
    type: "function",
    name: "decreaseLiquidity",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {name: "tokenId", type: "uint256"},
          {name: "liquidity", type: "uint128"},
          {name: "amount0Min", type: "uint256"},
          {name: "amount1Min", type: "uint256"},
          {name: "deadline", type: "uint256"},
        ],
      },
    ],
    outputs: [{name: "amount0", type: "uint256"}, {name: "amount1", type: "uint256"}],
  },
] as const;
