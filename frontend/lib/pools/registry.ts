import robinhoodManifest from "../deployments/robinhood.json";
import {robinhoodAssets, type RobinhoodSymbol} from "./assets";
import type {CuratedPool, DeployedPool, PoolCategory, PoolRiskDefaults, TradingHours} from "./types";

const ZERO = "0x0000000000000000000000000000000000000000";
const pendingOracleRequirement =
  "Pending verified oracle adapters, heartbeat configuration, and production pool deployment.";
const deployedNotLiveRequirement =
  "Deployment detected, but public activation waits for the coordinated all-18 launch.";

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
  ["GLD", "USDG", "stock-usdg", "equity-hours"],
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
  ["GLD", "SLV", "spread", "equity-hours"],
  ["WETH", "USDG", "crypto", "always-open"],
] as const satisfies readonly PairSpec[];

/** The subset of the deployment manifest the registry depends on. */
export type RegistryManifest = {
  launchStatus?: string;
  poolManager?: string;
  hook?: string;
  positionManager?: string;
  stakingToken?: string;
  pools?: readonly (Partial<DeployedPool> & {seeded?: boolean})[];
};

/**
 * Build the 18-pool catalog from a deployment manifest. Coordinated launch: every pool goes live
 * together, and only when the global `launchStatus` is "live", the core protocol addresses are
 * non-zero, and ALL 18 pools have complete receipt-backed deployments. Nothing shows live while
 * `launchStatus` is "pending". Only the seed set gets initial liquidity; `seeded` (from the manifest
 * pool entry) lets the UI invite the first LP into unseeded live pools.
 */
export function buildPoolRegistry(manifest: RegistryManifest): readonly CuratedPool[] {
  const deployedPools = (manifest.pools ?? []).filter(isDeployedPool);
  const protocolReady = [manifest.poolManager, manifest.hook, manifest.positionManager, manifest.stakingToken]
    .every((address) => !!address && address.toLowerCase() !== ZERO);

  const resolved = pairSpecs.map(([baseSymbol, quoteSymbol, category, tradingHours]) => {
    const base = robinhoodAssets[baseSymbol];
    const quote = robinhoodAssets[quoteSymbol];
    const slug = `${baseSymbol.toLowerCase()}-${quoteSymbol.toLowerCase()}`;
    const rawDeployment = deployedPools.find(
      (pool) => (!pool.slug || pool.slug === slug) && matchesPair(pool, base.address, quote.address),
    );
    const deployment = rawDeployment ? withTokenMetadata(rawDeployment, base, quote) : undefined;
    return {base, quote, category, tradingHours, slug, deployment, seeded: rawDeployment?.seeded === true};
  });
  const coordinatedLaunchReady =
    manifest.launchStatus === "live" &&
    protocolReady &&
    resolved.length === 18 &&
    resolved.every(({deployment}) => deployment !== undefined);

  return resolved.map(({base, quote, category, tradingHours, slug, deployment, seeded}) => ({
    slug,
    base,
    quote,
    category,
    tradingHours,
    risk: deployment ?? conservativeLaunchRisk,
    status: coordinatedLaunchReady ? "live" : "pending",
    seeded: coordinatedLaunchReady && seeded,
    deployment: coordinatedLaunchReady ? deployment : undefined,
    readinessRequirement: coordinatedLaunchReady
      ? undefined
      : deployment
        ? deployedNotLiveRequirement
        : pendingOracleRequirement,
  }) satisfies CuratedPool);
}

export const poolRegistry: readonly CuratedPool[] = buildPoolRegistry(robinhoodManifest as RegistryManifest);

export const defaultPool =
  poolRegistry.find((pool) => pool.status === "live" && pool.seeded) ??
  poolRegistry.find((pool) => pool.status === "live") ??
  poolRegistry[0];

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
    if (pool.seeded && pool.status !== "live") errors.push(`${pool.slug} is seeded but not live`);
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
  if (pool.slug === "weth-usdg") return true;
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
