import {poolKeyComponents} from "./poolKey";

export const swapRouterAbi = [
  {
    type: "function",
    name: "swap",
    stateMutability: "nonpayable",
    inputs: [
      {name: "key", type: "tuple", components: poolKeyComponents},
      {name: "zeroForOne", type: "bool"},
      {name: "amountIn", type: "uint256"},
      {name: "amountOutMinimum", type: "uint256"},
      {name: "recipient", type: "address"},
      {name: "hookData", type: "bytes"},
    ],
    outputs: [{name: "amountOut", type: "uint256"}],
  },
] as const;
