import {readFileSync} from "node:fs";

import {DYNAMIC_FEE} from "./abi.js";

const ZERO = "0x0000000000000000000000000000000000000000";

export type PoolKey = {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
};

export type LivePool = {
  slug: string;
  poolId: `0x${string}`;
  startBlock: number;
  key: PoolKey;
};

export type KeeperManifest = {
  chainId: number;
  hook: `0x${string}`;
  pools: LivePool[];
};

type RawPool = {
  slug?: string;
  poolId?: string;
  token0?: string;
  token1?: string;
  tickSpacing?: number;
  startBlock?: number;
  receipt?: string;
};

type RawManifest = {
  chainId?: number;
  hook?: string;
  launchStatus?: string;
  pools?: RawPool[];
};

export function loadManifest(path: string): KeeperManifest {
  const raw = JSON.parse(readFileSync(path, "utf8")) as RawManifest;
  const hook = (raw.hook ?? ZERO).toLowerCase() as `0x${string}`;
  const pools: LivePool[] = [];
  for (const pool of raw.pools ?? []) {
    if (!pool.poolId || !pool.token0 || !pool.token1 || !pool.tickSpacing || !pool.startBlock || !pool.receipt) continue;
    if (pool.token0.toLowerCase() === ZERO || pool.poolId.toLowerCase() === ZERO) continue;
    pools.push({
      slug: pool.slug ?? pool.poolId,
      poolId: pool.poolId as `0x${string}`,
      startBlock: pool.startBlock,
      key: {
        currency0: pool.token0 as `0x${string}`,
        currency1: pool.token1 as `0x${string}`,
        fee: DYNAMIC_FEE,
        tickSpacing: pool.tickSpacing,
        hooks: hook,
      },
    });
  }
  if (raw.launchStatus !== "live") pools.length = 0;
  return {chainId: raw.chainId ?? 0, hook, pools};
}

export function isDeployed(manifest: KeeperManifest): boolean {
  return manifest.hook !== ZERO && manifest.pools.length === 18 && new Set(manifest.pools.map((pool) => pool.slug)).size === 18;
}
