"use client";

import {useEffect, useMemo, useState} from "react";

import {indexerGraphql, items} from "@/lib/indexer/client";
import {classifySwaps, isIndexerStale, parseIndexedInt, txHashFromEventId, type IndexedSwap} from "@/lib/indexer/history";
import {useSelectedPool} from "./useSelectedPool";

export type SwapRow = IndexedSwap;

const SWAPS_QUERY = `
  query PoolSwaps($poolId: String!) {
    swaps(where: {poolId: $poolId}, orderBy: "timestamp", orderDirection: "asc", limit: 250) {
      items {
        id
        poolId
        blockNumber
        timestamp
        driftBps
        asymmetricActive
        structuralBreakTriggered
      }
    }
  }
`;

type SwapNode = {
  id: string;
  blockNumber: string | number | bigint;
  timestamp: string | number | bigint;
  driftBps: string | number | bigint;
  asymmetricActive: boolean;
  structuralBreakTriggered: boolean;
};

/**
 * Pool-filtered swap history from the configured Ponder API.
 * Live pool state stays on direct contract reads; this hook only replaces RPC log scans.
 */
export function useHookSwaps({refetchMs = 30_000}: {refetchMs?: number} = {}) {
  const {deployment} = useSelectedPool();
  const [rows, setRows] = useState<SwapRow[] | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [loading, setLoading] = useState(false);

  const poolId = deployment?.poolId;

  useEffect(() => {
    setRows(null);
    setError(null);
    if (!poolId) return;
    let cancelled = false;

    async function load() {
      setLoading(true);
      try {
        const data = await indexerGraphql<{swaps?: {items?: SwapNode[]}}>(SWAPS_QUERY, {poolId});
        const classified = classifySwaps(
          items(data.swaps).map((row) => ({
            id: row.id,
            blockNumber: parseIndexedInt(row.blockNumber),
            timestamp: parseIndexedInt(row.timestamp),
            driftBps: parseIndexedInt(row.driftBps),
            asymmetricActive: row.asymmetricActive,
            structuralBreakTriggered: row.structuralBreakTriggered,
            txHash: txHashFromEventId(row.id),
          })),
        );
        if (!cancelled) {
          setRows(classified);
          setError(null);
        }
      } catch (caught) {
        if (!cancelled) setError(caught as Error);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    const timer = setInterval(load, refetchMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [poolId, refetchMs]);

  const newest = useMemo(() => (rows ? [...rows].reverse() : null), [rows]);
  const stale = isIndexerStale(newest?.[0]?.timestamp) || !!error;

  return {rows, newest, loading, error, stale, deployment};
}
