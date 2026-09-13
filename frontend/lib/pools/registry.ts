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
  drawdownBps: 2000,
  vaultFeeBps: 2000,
  treasuryFeeBps: 1000,
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
  ["AAPL", "USDG", "stock-usdg", "equity-hours"],
  ["TSLA", "USDG", "stock-usdg", "equity-hours"],
  ["MSTR", "WETH", "stock-weth", "equity-hours"],
  ["COIN", "WETH", "stock-weth", "equity-hours"],
  ["QQQ", "WETH", "stock-weth", "equity-hours"],
  ["NVDA", "WETH", "stock-weth", "equity-hours"],
  ["PLTR", "WETH", "stock-weth", "equity-hours"],
  ["AAPL", "MSFT", "spread", "equity-hours"],
  ["SPY", "NVDA", "spread", "equity-hours"],
  ["SPY", "QQQ", "spread", "equity-hours"],
  ["WETH", "USDG", "crypto", "always-open"],
] as const satisfies readonly PairSpec[];

type RawManifest = {launchStatus?: string; pools?: readonly Partial<DeployedPool>[]};
const rawManifest = robinhoodManifest as RawManifest;
const manifestPools = rawManifest.launchStatus === "live"
  ? (rawManifest.pools ?? []).filter(isDeployedPool)
  : [];
const resolvedPairs = pairSpecs.map(([baseSymbol, quoteSymbol, category, tradingHours]) => {
    const base = robinhoodAssets[baseSymbol];
    const quote = robinhoodAssets[quoteSymbol];
    const slug = `${baseSymbol.toLowerCase()}-${quoteSymbol.toLowerCase()}`;
    const rawDeployment = manifestPools.find(
      (pool) => (!pool.slug || pool.slug === slug) && matchesPair(pool, base.address, quote.address),
    );
    const deployment = rawDeployment ? withTokenMetadata(rawDeployment, base, quote) : undefined;
    return {base, quote, category, tradingHours, slug, deployment};
  });
const protocolAddressesReady = [
  robinhoodManifest.poolManager,
  robinhoodManifest.hook,
  robinhoodManifest.positionManager,
  robinhoodManifest.stakingToken,
].every((address) => address && address !== ZERO);
const coordinatedLaunchReady =
  protocolAddressesReady && resolvedPairs.every(({deployment}) => deployment !== undefined);

export const poolRegistry: readonly CuratedPool[] = resolvedPairs.map(
  ({base, quote, category, tradingHours, slug, deployment}) => {
    return {
      slug,
      base,
      quote,
      category,
      tradingHours,
      risk: deployment ?? conservativeLaunchRisk,
      status: coordinatedLaunchReady ? "live" : "pending",
      deployment: coordinatedLaunchReady ? deployment : undefined,
      readinessRequirement: coordinatedLaunchReady
        ? undefined
        : deployment
          ? "Deployment detected, but public activation waits for the coordinated all-16 launch."
          : pendingOracleRequirement,
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
  const alwaysOpen = isWethUsdg(pool);
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
      pool.oracle1 !== ZERO &&
      (pool.marketHours !== ZERO || alwaysOpen),
  );
}

function isWethUsdg(pool: Partial<DeployedPool>): boolean {
  const symbols = [pool.token0Symbol?.toUpperCase(), pool.token1Symbol?.toUpperCase()];
  return symbols.includes("WETH") && symbols.includes("USDG");
}

function withTokenMetadata(
  pool: DeployedPool,
  base: CuratedPool["base"],
  quote: CuratedPool["quote"],
): DeployedPool {
  const token0IsBase = pool.token0.toLowerCase() === base.address.toLowerCase();
  return {
    ...pool,
    token0Symbol: token0IsBase ? base.symbol : quote.symbol,
    token1Symbol: token0IsBase ? quote.symbol : base.symbol,
    token0Decimals: token0IsBase ? base.decimals : quote.decimals,
    token1Decimals: token0IsBase ? quote.decimals : base.decimals,
  };
}
