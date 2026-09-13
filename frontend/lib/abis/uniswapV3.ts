export const uniswapV3QuoterAbi = [
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "nonpayable",
    inputs: [
      {name: "path", type: "bytes"},
      {name: "amountIn", type: "uint256"},
    ],
    outputs: [
      {name: "amountOut", type: "uint256"},
      {name: "sqrtPriceX96AfterList", type: "uint160[]"},
      {name: "initializedTicksCrossedList", type: "uint32[]"},
      {name: "gasEstimate", type: "uint256"},
    ],
  },
] as const;

export const uniswapV3RouterAbi = [
  {
    type: "function",
    name: "exactInput",
    stateMutability: "payable",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          {name: "path", type: "bytes"},
          {name: "recipient", type: "address"},
          {name: "amountIn", type: "uint256"},
          {name: "amountOutMinimum", type: "uint256"},
        ],
      },
    ],
    outputs: [{name: "amountOut", type: "uint256"}],
  },
] as const;
