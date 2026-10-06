import {deployment} from "./deployment";

const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;
const POOL_ID_PATTERN = /^0x[0-9a-fA-F]{64}$/;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;
const ZERO_POOL_ID = `0x${"0".repeat(64)}` as `0x${string}`;

export type VaultPool = {
  vault: `0x${string}`;
  poolId: `0x${string}`;
};

/**
 * Parses `vault=poolId` entries separated by commas.
 * A zero placeholder keeps codegen usable before production addresses exist.
 */
export function parseVaultPools(value: string | undefined): VaultPool[] {
  if (!value?.trim()) return [{vault: ZERO_ADDRESS, poolId: ZERO_POOL_ID}];

  const seenVaults = new Set<string>();
  const seenPools = new Set<string>();

  return value.split(",").map((rawEntry, index) => {
    const entry = rawEntry.trim();
    const parts = entry.split("=");
    if (parts.length !== 2) {
      throw new Error(`PONDER_VAULTS entry ${index + 1} must be vault=poolId`);
    }

    const [vault, poolId] = parts.map((part) => part.trim());
    if (!ADDRESS_PATTERN.test(vault)) {
      throw new Error(`PONDER_VAULTS entry ${index + 1} has an invalid vault address`);
    }
    if (!POOL_ID_PATTERN.test(poolId)) {
      throw new Error(`PONDER_VAULTS entry ${index + 1} has an invalid bytes32 pool ID`);
    }

    const vaultKey = vault.toLowerCase();
    const poolKey = poolId.toLowerCase();
    if (seenVaults.has(vaultKey)) throw new Error(`PONDER_VAULTS contains duplicate vault ${vault}`);
    if (seenPools.has(poolKey)) throw new Error(`PONDER_VAULTS contains duplicate pool ID ${poolId}`);
    seenVaults.add(vaultKey);
    seenPools.add(poolKey);

    return {vault: vault as `0x${string}`, poolId: poolId as `0x${string}`};
  });
}

function manifestVaultPools(): VaultPool[] {
  if (deployment.launchStatus !== "live") return [];
  const pools = (deployment.pools ?? []).map((pool) => {
    if (!pool.vault || !pool.poolId || !pool.startBlock) {
      throw new Error("live manifest contains a pool without receipt-backed vault metadata");
    }
    return {vault: pool.vault as `0x${string}`, poolId: pool.poolId as `0x${string}`};
  });
  if (pools.length !== 18) throw new Error("live manifest must contain all 18 pools");
  return pools;
}

const fromManifest = manifestVaultPools();
export const vaultPools = fromManifest.length > 0
  ? fromManifest
  : parseVaultPools(process.env.PONDER_VAULTS);

export const poolIdByVault = new Map(
  vaultPools.map(({vault, poolId}) => [vault.toLowerCase(), poolId] as const),
);

export function poolIdForVault(vault: string): `0x${string}` {
  const poolId = poolIdByVault.get(vault.toLowerCase());
  if (!poolId) throw new Error(`No pool ID configured for vault ${vault}`);
  return poolId;
}
