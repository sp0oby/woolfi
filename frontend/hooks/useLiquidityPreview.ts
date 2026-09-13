"use client";

import {useEffect, useState} from "react";
import {useChainId, usePublicClient} from "wagmi";

import {pmAbi} from "@/lib/abis";
import type {PoolKey} from "@/lib/poolKey";

type PreviewArgs = {
  positionManager: `0x${string}`;
  poolKey: PoolKey;
  amount0: bigint | undefined;
  amount1: bigint | undefined;
  account: `0x${string}` | undefined;
  enabled: boolean;
};

export function useLiquidityPreview({
  positionManager,
  poolKey,
  amount0,
  amount1,
  account,
  enabled,
}: PreviewArgs) {
  const chainId = useChainId();
  const publicClient = usePublicClient({chainId});
  const [shares, setShares] = useState<bigint>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(false);
  const keyId = `${poolKey.currency0}|${poolKey.currency1}|${poolKey.fee}|${poolKey.tickSpacing}|${poolKey.hooks}`;

  useEffect(() => {
    if (!publicClient || !account || !enabled || !amount0 || !amount1) {
      setShares(undefined);
      setError(undefined);
      setLoading(false);
      return;
    }

    let cancelled = false;
    const timer = setTimeout(() => {
      setLoading(true);
      publicClient
        .readContract({
          address: positionManager,
          abi: pmAbi,
          functionName: "previewMint",
          args: [poolKey, amount0, amount1],
        })
        .then((result) => {
          if (cancelled) return;
          setShares(result);
          setError(undefined);
        })
        .catch((cause: unknown) => {
          if (cancelled) return;
          const failure = cause as {shortMessage?: string; message?: string};
          setShares(undefined);
          setError(failure.shortMessage ?? failure.message ?? "Liquidity simulation failed");
        })
        .finally(() => {
          if (!cancelled) setLoading(false);
        });
    }, 400);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [publicClient, positionManager, keyId, amount0, amount1, account, enabled]);

  return {shares, error, loading};
}
