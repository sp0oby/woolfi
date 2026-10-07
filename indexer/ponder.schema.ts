import {onchainTable} from "ponder";

/**
 * Indexer schema for the WoolFi dashboard. Each row is uniquely identified by `txHash-logIndex`
 * so re-orgs are handled idempotently.
 */

// Every swap, with the hook's classification.
export const swap = onchainTable("swap", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  driftBps: t.bigint().notNull(), // signed; stored as bigint
  asymmetricActive: t.boolean().notNull(),
  structuralBreakTriggered: t.boolean().notNull(),
}));

// Each structural-break event (set + resolved).
export const structuralBreak = onchainTable("structural_break", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  driftBps: t.bigint().notNull(),
  resolved: t.boolean().notNull().default(false),
  cachedFairPriceWad: t.bigint(),
}));

// One row per two-phase break episode: detected -> (confirmed with drawdown | cleared without one)
// -> (recovered permissionlessly | resolved by the governor). `outcome` is the latest state.
export const breakEpisode = onchainTable("break_episode", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  detectedAt: t.bigint().notNull(),
  detectedBlock: t.bigint().notNull(),
  detectedDriftBps: t.bigint().notNull(),
  cachedFairPriceWad: t.bigint(),
  confirmedAt: t.bigint(),
  confirmedDriftBps: t.bigint(),
  drawdownFailed: t.boolean().notNull().default(false),
  drawdownFailureReason: t.hex(),
  clearedAt: t.bigint(),
  clearedDriftBps: t.bigint(),
  recoveredAt: t.bigint(),
  recoveredDriftBps: t.bigint(),
  resolvedAt: t.bigint(),
  outcome: t.text().notNull(),
}));

// Pointer from a pool to its currently open (or most recent) episode.
export const poolBreakPointer = onchainTable("pool_break_pointer", (t) => ({
  id: t.hex().primaryKey(),
  episodeId: t.text().notNull(),
  open: t.boolean().notNull(),
}));

export const breakConfirmSetting = onchainTable("break_confirm_setting", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  confirmSeconds: t.integer().notNull(),
}));

export const oracleSkew = onchainTable("oracle_skew", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  updatedAt0: t.bigint().notNull(),
  updatedAt1: t.bigint().notNull(),
  maxSkew: t.integer().notNull(),
}));

export const poolSafety = onchainTable("pool_safety", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  stabilizationSeconds: t.integer().notNull(),
  maxOracleSkew: t.integer().notNull(),
}));

// LP mint/burn events through the position manager.
export const lpMovement = onchainTable("lp_movement", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  account: t.hex().notNull(),
  kind: t.text().notNull(), // "mint" | "burn"
  liquidity: t.bigint().notNull(),
  amount0: t.bigint().notNull(),
  amount1: t.bigint().notNull(),
}));

// Fee routing each time the PM realizes pool fees.
export const feeRouting = onchainTable("fee_routing", (t) => ({
  id: t.text().primaryKey(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  vault0: t.bigint().notNull(),
  vault1: t.bigint().notNull(),
  treasury0: t.bigint().notNull(),
  treasury1: t.bigint().notNull(),
}));

// Vault stake / unstake / drawdown.
export const vaultEvent = onchainTable("vault_event", (t) => ({
  id: t.text().primaryKey(),
  vault: t.hex().notNull(),
  poolId: t.hex().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  kind: t.text().notNull(), // "stake" | "unstake" | "drawdown"
  user: t.hex(),
  amount: t.bigint().notNull(),
  shares: t.bigint(),
  totalStakedAfter: t.bigint(),
}));

// Rebate configuration, funding, accrual, and claims. Fields that do not apply to an event kind
// remain null; amounts are always raw token units.
export const rebateEvent = onchainTable("rebate_event", (t) => ({
  id: t.text().primaryKey(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  kind: t.text().notNull(),
  trader: t.hex(),
  poolId: t.hex(),
  token: t.hex(),
  recipient: t.hex(),
  router: t.hex(),
  amount: t.bigint(),
  week: t.bigint(),
}));
