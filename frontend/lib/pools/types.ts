export type Address = `0x${string}`;

export type AssetKind = "stock" | "etf" | "crypto" | "stable" | "staking";

export type PoolCategory = "stock-usdg" | "stock-weth" | "spread" | "crypto";
export type TradingHours = "always-open" | "equity-hours";
export type PoolStatus = "pending" | "live";

export type CuratedAsset = {
  symbol: string;
  name: string;
  kind: AssetKind;
  address: Address;
  decimals: number;
};

export type PoolRiskDefaults = {
  tickSpacing: number;
  baseFeeBps: number;
  toleranceBps: number;
  hardThresholdBps: number;
  drawdownBps: number;
  vaultFeeBps: number;
  treasuryFeeBps: number;
};

export type DeployedPool = PoolRiskDefaults & {
  poolId: `0x${string}`;
  slug?: string;
  token0: Address;
  token1: Address;
  token0Symbol: string;
  token1Symbol: string;
  token0Decimals: number;
  token1Decimals: number;
  oracle0: Address;
  oracle1: Address;
  marketHours: Address;
  vault: Address;
  startBlock?: number;
  /** Manifest flag: true when this pool received initial seed liquidity (batch config `seedSet`). */
  seeded?: boolean;
};

export type CuratedPool = {
  slug: string;
  base: CuratedAsset;
  quote: CuratedAsset;
  category: PoolCategory;
  tradingHours: TradingHours;
  risk: PoolRiskDefaults;
  status: PoolStatus;
  /**
   * True only for live pools that received initial seed liquidity at launch (the batch config's
   * `seedSet`). A live pool with `seeded: false` was initialized at the launch price with zero
   * liquidity and needs a first LP.
   */
  seeded: boolean;
  deployment?: DeployedPool;
  readinessRequirement?: string;
};
