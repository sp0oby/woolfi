/**
 * Minimal WoolFi event ABIs for the indexer.
 *
 * Only the events we actually consume are listed — extend per `src/index.ts` as the dashboard
 * grows. Sourced from the Solidity contracts in `../../src/`; keep these in sync when contract
 * events change (or wire ponder to read from `../../out/*.json` once the contracts are deployed).
 */

export const woolfiHookAbi = [
  {
    type: "event",
    name: "SwapProcessed",
    inputs: [
      {indexed: true, name: "id", type: "bytes32"},
      {indexed: false, name: "driftBps", type: "int256"},
      {indexed: false, name: "asymmetricActive", type: "bool"},
      {indexed: false, name: "structuralBreakTriggered", type: "bool"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "StructuralBreakTriggered",
    inputs: [
      {indexed: true, name: "id", type: "bytes32"},
      {indexed: false, name: "driftBps", type: "int256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "StructuralBreakResolved",
    inputs: [{indexed: true, name: "id", type: "bytes32"}],
    anonymous: false,
  },
  {
    type: "event",
    name: "StructuralBreakTargetCached",
    inputs: [
      {indexed: true, name: "id", type: "bytes32"},
      {indexed: false, name: "fairPriceWad", type: "uint256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "OracleSkewObserved",
    inputs: [
      {indexed: true, name: "id", type: "bytes32"},
      {indexed: false, name: "updatedAt0", type: "uint256"},
      {indexed: false, name: "updatedAt1", type: "uint256"},
      {indexed: false, name: "maxSkew", type: "uint32"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "PoolSafetyUpdated",
    inputs: [
      {indexed: true, name: "id", type: "bytes32"},
      {indexed: false, name: "stabilizationSeconds", type: "uint32"},
      {indexed: false, name: "maxOracleSkew", type: "uint32"},
    ],
    anonymous: false,
  },
] as const;

export const woolfiPositionManagerAbi = [
  {
    type: "event",
    name: "Mint",
    inputs: [
      {indexed: true, name: "id", type: "uint256"},
      {indexed: true, name: "to", type: "address"},
      {indexed: false, name: "liquidity", type: "uint128"},
      {indexed: false, name: "amount0", type: "uint256"},
      {indexed: false, name: "amount1", type: "uint256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Burn",
    inputs: [
      {indexed: true, name: "id", type: "uint256"},
      {indexed: true, name: "from", type: "address"},
      {indexed: false, name: "liquidity", type: "uint128"},
      {indexed: false, name: "amount0", type: "uint256"},
      {indexed: false, name: "amount1", type: "uint256"},
    ],
    anonymous: false,
  },
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

export const woolfiUnderwritingVaultAbi = [
  {
    type: "event",
    name: "Staked",
    inputs: [
      {indexed: true, name: "user", type: "address"},
      {indexed: false, name: "amount", type: "uint256"},
      {indexed: false, name: "shares", type: "uint256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Unstaked",
    inputs: [
      {indexed: true, name: "user", type: "address"},
      {indexed: false, name: "shares", type: "uint256"},
      {indexed: false, name: "amount", type: "uint256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Drawdown",
    inputs: [
      {indexed: false, name: "seized", type: "uint256"},
      {indexed: false, name: "totalStakedAfter", type: "uint256"},
    ],
    anonymous: false,
  },
] as const;

export const urufuFeeRebateDistributorAbi = [
  {
    type: "event",
    name: "RouterSet",
    inputs: [{indexed: true, name: "router", type: "address"}],
    anonymous: false,
  },
  {
    type: "event",
    name: "WeeklyCapSet",
    inputs: [
      {indexed: true, name: "token", type: "address"},
      {indexed: false, name: "cap", type: "uint256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "Funded",
    inputs: [
      {indexed: true, name: "funder", type: "address"},
      {indexed: true, name: "token", type: "address"},
      {indexed: false, name: "amount", type: "uint256"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "RebateAccrued",
    inputs: [
      {indexed: true, name: "trader", type: "address"},
      {indexed: true, name: "poolId", type: "bytes32"},
      {indexed: true, name: "token", type: "address"},
      {indexed: false, name: "amount", type: "uint256"},
      {indexed: false, name: "week", type: "uint64"},
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "RebateClaimed",
    inputs: [
      {indexed: true, name: "trader", type: "address"},
      {indexed: true, name: "token", type: "address"},
      {indexed: true, name: "recipient", type: "address"},
      {indexed: false, name: "amount", type: "uint256"},
    ],
    anonymous: false,
  },
] as const;
