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
};

export type PoolRiskDefaults = {
  tickSpacing: number;
  baseFeeBps: number;
  toleranceBps: number;
  hardThresholdBps: number;
  drawdownBps: number;
  vaultFeeBps: number;
  buybackBps: number;
};

export type DeployedPool = PoolRiskDefaults & {
  poolId: `0x${string}`;
  slug?: string;
  token0: Address;
  token1: Address;
  token0Symbol: string;
  token1Symbol: string;
  oracle0: Address;
  oracle1: Address;
  marketHours: Address;
  vault: Address;
  startBlock?: number;
};

export type CuratedPool = {
  slug: string;
  base: CuratedAsset;
  quote: CuratedAsset;
  category: PoolCategory;
  tradingHours: TradingHours;
  risk: PoolRiskDefaults;
  status: PoolStatus;
  deployment?: DeployedPool;
  readinessRequirement?: string;
};
