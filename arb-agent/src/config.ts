import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {DYNAMIC_FEE} from "./abi.js";

const ZERO = "0x0000000000000000000000000000000000000000";
export type Address = `0x${string}`;

export type PoolKey = {currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address};

export type ArbPool = {
  slug: string;
  key: PoolKey;
  oracle0: Address;
  oracle1: Address;
};

export type AgentConfig = {
  rpcUrl: string;
  manifestPath: string;
  executor?: Address;
  privateKey?: Address;
  broadcast: boolean;
  cadenceMs: number;
  minProfitUsd: number;
  minDriftBps: number;
  sizesUsd: number[];
  v3Factory: Address;
  v3Quoter: Address;
  explainEveryTicks: number;
  anthropicApiKey?: string;
  reportWebhook?: string;
};

/** Read every setting from the environment. Broadcasting is off unless ARB_BROADCAST=true. */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AgentConfig {
  const broadcast = env.ARB_BROADCAST === "true";
  const privateKey = env.ARB_PRIVATE_KEY as Address | undefined;
  if (broadcast && !privateKey) throw new Error("ARB_BROADCAST=true requires ARB_PRIVATE_KEY");
  return {
    rpcUrl: env.ROBINHOOD_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com",
    manifestPath: env.ARB_MANIFEST ?? resolve("../frontend/lib/deployments/robinhood.json"),
    executor: optionalAddress(env.ARB_EXECUTOR),
    privateKey,
    broadcast,
    cadenceMs: Number(env.ARB_CADENCE_MS ?? 15_000),
    minProfitUsd: Number(env.ARB_MIN_PROFIT_USD ?? 1),
    minDriftBps: Number(env.ARB_MIN_DRIFT_BPS ?? 40),
    sizesUsd: (env.ARB_SIZES_USD ?? "250,500,1000,2000,5000,10000").split(",").map(Number).filter((n) => n > 0),
    v3Factory: (env.ARB_V3_FACTORY ?? "0x1f7d7550b1b028f7571e69a784071f0205fd2efa") as Address,
    v3Quoter: (env.ARB_V3_QUOTER ?? "0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7") as Address,
    explainEveryTicks: Number(env.ARB_EXPLAIN_EVERY_TICKS ?? 20),
    anthropicApiKey: env.ANTHROPIC_API_KEY || undefined,
    reportWebhook: env.ARB_REPORT_WEBHOOK || undefined,
  };
}

type RawManifest = {
  chainId?: number;
  hook?: string;
  launchStatus?: string;
  pools?: {slug?: string; token0?: string; token1?: string; tickSpacing?: number; oracle0?: string; oracle1?: string}[];
};

/** Live pools from the shared deployment manifest. Returns [] until launchStatus is "live". */
export function loadPools(path: string): {chainId: number; pools: ArbPool[]} {
  const raw = JSON.parse(readFileSync(path, "utf8")) as RawManifest;
  const hook = (raw.hook ?? ZERO) as Address;
  if (raw.launchStatus !== "live" || hook.toLowerCase() === ZERO) return {chainId: raw.chainId ?? 0, pools: []};
  const pools: ArbPool[] = [];
  for (const p of raw.pools ?? []) {
    if (!p.token0 || !p.token1 || !p.tickSpacing || !p.oracle0 || !p.oracle1) continue;
    if ([p.token0, p.token1, p.oracle0, p.oracle1].some((a) => a.toLowerCase() === ZERO)) continue;
    pools.push({
      slug: p.slug ?? `${p.token0}-${p.token1}`,
      key: {
        currency0: p.token0 as Address,
        currency1: p.token1 as Address,
        fee: DYNAMIC_FEE,
        tickSpacing: p.tickSpacing,
        hooks: hook,
      },
      oracle0: p.oracle0 as Address,
      oracle1: p.oracle1 as Address,
    });
  }
  return {chainId: raw.chainId ?? 0, pools};
}

function optionalAddress(value: string | undefined): Address | undefined {
  if (!value || value.toLowerCase() === ZERO) return undefined;
  return value as Address;
}
