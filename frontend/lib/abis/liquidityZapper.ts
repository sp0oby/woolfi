import {poolKeyComponents} from "./poolKey";

const swapPlanComponents = [
  {name: "executor", type: "address"},
  {name: "tokenOut", type: "address"},
  {name: "amountIn", type: "uint256"},
  {name: "minAmountOut", type: "uint256"},
  {name: "data", type: "bytes"},
] as const;

export const liquidityZapperAbi = [
  {
    type: "function",
    name: "zap",
    stateMutability: "payable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          {name: "key", type: "tuple", components: poolKeyComponents},
          {name: "tokenIn", type: "address"},
          {name: "amountIn", type: "uint256"},
          {name: "swap0", type: "tuple", components: swapPlanComponents},
          {name: "swap1", type: "tuple", components: swapPlanComponents},
          {name: "minShares", type: "uint128"},
          {name: "deadline", type: "uint256"},
          {name: "recipient", type: "address"},
        ],
      },
    ],
    outputs: [{name: "shares", type: "uint128"}],
  },
] as const;
