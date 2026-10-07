import {poolKeyComponents} from "./poolKey";

/** WoolFiPoolAligner: moves an EMPTY pool to its oracle fair price at zero cost. Permissionless. */
export const poolAlignerAbi = [
  {
    type: "function",
    name: "align",
    stateMutability: "nonpayable",
    inputs: [{name: "key", type: "tuple", components: poolKeyComponents}],
    outputs: [{name: "moved", type: "bool"}],
  },
  {type: "error", name: "PoolHasLiquidity", inputs: [{name: "liquidity", type: "uint128"}]},
  {type: "error", name: "PoolNotConfigured", inputs: []},
  {type: "error", name: "NonZeroDelta", inputs: []},
  {type: "error", name: "NotPoolManager", inputs: []},
] as const;
