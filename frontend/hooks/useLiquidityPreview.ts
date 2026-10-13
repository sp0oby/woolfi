"use client";

import {useEffect, useState} from "react";
import {usePublicClient} from "wagmi";

import {pmAbi} from "@/lib/abis";
import type {PoolKey} from "@/lib/poolKey";
import {inputsKey, readKeyed, type Keyed} from "@/lib/txGuards";
import {robinhood} from "@/lib/wagmi";

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
  // Reads stay pinned to Robinhood Chain whatever chain the wallet is on.
  const publicClient = usePublicClient({chainId: robinhood.id});
  // The preview is stored with the inputs that produced it and only exposed while they still
  // match, so a deposit can never take its minShares bound from older amounts.
  const [result, setResult] = useState<Keyed<bigint>>();
  const keyId = `${poolKey.currency0}|${poolKey.currency1}|${poolKey.fee}|${poolKey.tickSpacing}|${poolKey.hooks}`;
  const active = !!publicClient && !!account && enabled && !!amount0 && !!amount1;
  const key = inputsKey(positionManager, keyId, amount0, amount1, account);

  useEffect(() => {
    if (!active || !publicClient || !amount0 || !amount1) return;

    let cancelled = false;
    const timer = setTimeout(() => {
      publicClient
        .readContract({
          address: positionManager,
          abi: pmAbi,
          functionName: "previewMint",
          args: [poolKey, amount0, amount1],
        })
        .then((shares) => {
          if (!cancelled) setResult({key, value: shares});
        })
        .catch((cause: unknown) => {
          if (cancelled) return;
          const failure = cause as {shortMessage?: string; message?: string};
          setResult({key, error: failure.shortMessage ?? failure.message ?? "Liquidity simulation failed"});
        });
    }, 400);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, key]);

  const current = readKeyed(result, key);
  return {
    shares: active ? current.value : undefined,
    error: active ? current.error : undefined,
    loading: active && !current.fresh,
  };
}
