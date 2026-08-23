import robinhoodManifest from "../deployments/robinhood.json";
import {robinhoodAssets, type RobinhoodSymbol} from "./assets";
import type {CuratedPool, DeployedPool, PoolCategory, PoolRiskDefaults, TradingHours} from "./types";

const ZERO = "0x0000000000000000000000000000000000000000";
const pendingOracleRequirement =
  "Pending verified oracle adapters, heartbeat configuration, and production pool deployment.";

export const conservativeLaunchRisk = {
  tickSpacing: 60,
  baseFeeBps: 30,
  toleranceBps: 500,
  hardThresholdBps: 1500,
  drawdownBps: 1000,
  vaultFeeBps: 2000,
  buybackBps: 1000,
} as const satisfies PoolRiskDefaults;

type PairSpec = readonly [
  base: RobinhoodSymbol,
  quote: RobinhoodSymbol,
  category: PoolCategory,
  tradingHours: TradingHours,
];

const pairSpecs = [
  ["MSTR", "USDG", "stock-usdg", "equity-hours"],
  ["COIN", "USDG", "stock-usdg", "equity-hours"],
  ["CRCL", "USDG", "stock-usdg", "equity-hours"],
  ["NVDA", "USDG", "stock-usdg", "equity-hours"],
  ["SPY", "USDG", "stock-usdg", "equity-hours"],
  ["GLD", "USDG", "stock-usdg", "equity-hours"],
  ["MSTR", "WETH", "stock-weth", "equity-hours"],
  ["COIN", "WETH", "stock-weth", "equity-hours"],
  ["QQQ", "WETH", "stock-weth", "equity-hours"],
  ["NVDA", "WETH", "stock-weth", "equity-hours"],
  ["PLTR", "WETH", "stock-weth", "equity-hours"],
  ["AAPL", "MSFT", "spread", "equity-hours"],
  ["NVDA", "SMH", "spread", "equity-hours"],
  ["SMH", "SOXX", "spread", "equity-hours"],
  ["XLK", "QQQ", "spread", "equity-hours"],
  ["SPY", "QQQ", "spread", "equity-hours"],
  ["GLD", "SLV", "spread", "equity-hours"],
  ["WETH", "USDG", "crypto", "always-open"],
] as const satisfies readonly PairSpec[];

type RawManifest = {pools?: readonly Partial<DeployedPool>[]};
const deployedPools = ((robinhoodManifest as RawManifest).pools ?? []).filter(isDeployedPool);

export const poolRegistry: readonly CuratedPool[] = pairSpecs.map(
  ([baseSymbol, quoteSymbol, category, tradingHours]) => {
    const base = robinhoodAssets[baseSymbol];
    const quote = robinhoodAssets[quoteSymbol];
    const slug = `${baseSymbol.toLowerCase()}-${quoteSymbol.toLowerCase()}`;
    const deployment = deployedPools.find(
      (pool) => (!pool.slug || pool.slug === slug) && matchesPair(pool, base.address, quote.address),
    );
    return {
      slug,
      base,
      quote,
      category,
      tradingHours,
      risk: deployment ?? conservativeLaunchRisk,
      status: deployment ? "live" : "pending",
      deployment,
      readinessRequirement: deployment ? undefined : pendingOracleRequirement,
    };
  },
);

export const defaultPool =
  poolRegistry.find((pool) => pool.status === "live") ?? poolRegistry[0];

export function findPoolBySlug(slug: string | null | undefined): CuratedPool | undefined {
  return slug ? poolRegistry.find((pool) => pool.slug === slug) : undefined;
}

export function filterPools(
  pools: readonly CuratedPool[],
  query: string,
  category: "all" | PoolCategory,
): CuratedPool[] {
  const needle = query.trim().toLowerCase();
  return pools.filter((pool) => {
    const haystack = [
      pool.slug,
      pool.base.symbol,
      pool.quote.symbol,
      pool.base.name,
      pool.quote.name,
    ].join(" ").toLowerCase();
    return (category === "all" || pool.category === category) && (!needle || haystack.includes(needle));
  });
}

export function validatePoolRegistry(pools: readonly CuratedPool[] = poolRegistry): string[] {
  const errors: string[] = [];
  const slugs = new Set<string>();
  const pairs = new Set<string>();
  for (const pool of pools) {
    if (slugs.has(pool.slug)) errors.push(`Duplicate pool slug: ${pool.slug}`);
    slugs.add(pool.slug);
    const base = pool.base.address.toLowerCase();
    const quote = pool.quote.address.toLowerCase();
    if (base === quote) {
      errors.push(`${pool.slug} uses the same asset twice`);
    }
    const pairKey = [base, quote].sort().join(":");
    if (pairs.has(pairKey)) errors.push(`Duplicate or reversed pool pair: ${pool.slug}`);
    pairs.add(pairKey);
    if (pool.status === "live" && !pool.deployment) errors.push(`${pool.slug} is live without deployment data`);
    if (pool.status === "pending" && pool.deployment) errors.push(`${pool.slug} is pending with deployment data`);
  }
  return errors;
}

const registryErrors = validatePoolRegistry();
if (registryErrors.length > 0) throw new Error(`Invalid pool registry: ${registryErrors.join("; ")}`);

function matchesPair(pool: DeployedPool, a: string, b: string): boolean {
  const tokens = [pool.token0.toLowerCase(), pool.token1.toLowerCase()];
  return tokens.includes(a.toLowerCase()) && tokens.includes(b.toLowerCase());
}

function isDeployedPool(pool: Partial<DeployedPool>): pool is DeployedPool {
  return Boolean(
    pool.poolId &&
      pool.token0 &&
      pool.token1 &&
      pool.vault &&
      pool.oracle0 &&
      pool.oracle1 &&
      pool.marketHours &&
      pool.vault !== ZERO &&
      pool.oracle0 !== ZERO &&
      pool.oracle1 !== ZERO,
  );
}
