"use client";

import {useEffect, useState} from "react";

import {indexerGraphql, items} from "@/lib/indexer/client";
import {isIndexerStale, parseIndexedInt} from "@/lib/indexer/history";
import {useSelectedPool} from "./useSelectedPool";

const FEES_QUERY = `
  query PoolFees($poolId: String!) {
    feeRoutings(where: {poolId: $poolId}, orderBy: "timestamp", orderDirection: "asc", limit: 500) {
      items { id timestamp vault0 vault1 buyback0 buyback1 }
    }
  }
`;

type FeeNode = {
  id: string;
  timestamp: string | number | bigint;
  vault0: string | number | bigint;
  vault1: string | number | bigint;
  buyback0: string | number | bigint;
  buyback1: string | number | bigint;
};

/**
 * Sums vault + buyback cuts for the selected pool from the Ponder fee-routing table.
 */
export function useRoutedFees({refetchMs = 30_000}: {refetchMs?: number} = {}) {
  const {deployment} = useSelectedPool();
  const [fee0, setFee0] = useState<bigint | undefined>(undefined);
  const [fee1, setFee1] = useState<bigint | undefined>(undefined);
  const [error, setError] = useState<Error | null>(null);
  const [stale, setStale] = useState(false);

  const poolId = deployment?.poolId;

  useEffect(() => {
    setFee0(undefined);
    setFee1(undefined);
    setError(null);
    setStale(false);
    if (!poolId) return;
    let cancelled = false;

    async function load() {
      try {
        const data = await indexerGraphql<{feeRoutings?: {items?: FeeNode[]}}>(FEES_QUERY, {
          poolId,
        });
        const rows = items(data.feeRoutings);
        let next0 = 0n;
        let next1 = 0n;
        let newest: bigint | undefined;
        for (const row of rows) {
          next0 += parseIndexedInt(row.vault0) + parseIndexedInt(row.buyback0);
          next1 += parseIndexedInt(row.vault1) + parseIndexedInt(row.buyback1);
          const timestamp = parseIndexedInt(row.timestamp);
          if (newest === undefined || timestamp > newest) newest = timestamp;
        }
        if (!cancelled) {
          setFee0(next0);
          setFee1(next1);
          setError(null);
          setStale(isIndexerStale(newest));
        }
      } catch (caught) {
        if (!cancelled) {
          setError(caught as Error);
          setStale(true);
        }
      }
    }

    load();
    const timer = setInterval(load, refetchMs);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [poolId, refetchMs]);

  return {fee0, fee1, error, stale};
}
