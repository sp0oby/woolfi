"use client";

import {useEffect, useState} from "react";
import {useChainId, usePublicClient} from "wagmi";

import {swapRouterAbi} from "@/lib/abis";
import {type PoolKey} from "@/lib/poolKey";

const ZERO_BYTES = "0x" as const;

/**
 * Pre-flight quote for a swap via `WoolFiSwapRouter`. We `simulateContract` against the router
 * with `amountOutMinimum = 0` so the simulation never reverts on slippage - only on the actual
 * preconditions (allowance, pool state, oracle staleness, etc). The returned `amountOut` is the
 * exact value the next real swap would settle, which we use to compute a correct min-out.
 *
 * Returns `quote = undefined` while loading or unsupported; `error` carries the revert reason
 * (e.g. "ERC20: insufficient allowance" if the user hasn't approved yet) so the panel can
 * surface it instead of letting MetaMask report it as "exceeds max transaction gas limit".
 */
export function useSwapQuote({
  router,
  poolKey,
  zeroForOne,
  amountIn,
  account,
}: {
  router: `0x${string}` | undefined;
  poolKey: PoolKey | undefined;
  zeroForOne: boolean;
  amountIn: bigint | undefined;
  account: `0x${string}` | undefined;
}) {
  const chainId = useChainId();
  const publicClient = usePublicClient({chainId});
  const [quote, setQuote] = useState<bigint | undefined>(undefined);
  const [error, setError] = useState<string | undefined>(undefined);
  const [loading, setLoading] = useState(false);

  // CRITICAL: poolKey is a fresh object literal on every parent render, so it can't go into
  // the dep array directly - the effect would re-run on every render, perpetually clearing the
  // debounce timer before it ever fires (this caused the "stuck on quoting" symptom). We derive
  // a stable string id from its fields and depend on that instead.
  const poolKeyId = poolKey
    ? `${poolKey.currency0}|${poolKey.currency1}|${poolKey.fee}|${poolKey.tickSpacing}|${poolKey.hooks}`
    : "";

  useEffect(() => {
    if (!publicClient || !router || !poolKey || !account) {
      setQuote(undefined);
      setError(undefined);
      return;
    }
    if (!amountIn || amountIn === 0n) {
      setQuote(undefined);
      setError(undefined);
      return;
    }

    let cancelled = false;
    // Debounce: wait 400ms after the last input change before firing the simulate. Stops the
    // RPC flood that used to happen when the user typed an amount character-by-character.
    const timer = setTimeout(() => {
      setLoading(true);
      publicClient
        .simulateContract({
          address: router,
          abi: swapRouterAbi,
          functionName: "swap",
          args: [poolKey, zeroForOne, amountIn, 0n, account, ZERO_BYTES],
          account,
        })
        .then((res) => {
          if (cancelled) return;
          setQuote(res.result as bigint);
          setError(undefined);
        })
        .catch((e) => {
          if (cancelled) return;
          setQuote(undefined);
          setError(extractRevertReason(e));
        })
        .finally(() => {
          if (!cancelled) setLoading(false);
        });
    }, 400);

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [publicClient, router, poolKeyId, zeroForOne, amountIn, account]);

  return {quote, error, loading};
}

function extractRevertReason(e: unknown): string {
  const err = e as {shortMessage?: string; message?: string};
  // viem ContractFunctionExecutionError formats nicely in shortMessage
  return err.shortMessage ?? err.message ?? "Simulation failed";
}
