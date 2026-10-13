"use client";

import {useEffect, useState} from "react";
import {usePublicClient} from "wagmi";

import {swapRouterAbi} from "@/lib/abis";
import {type PoolKey} from "@/lib/poolKey";
import {inputsKey, readKeyed, type Keyed} from "@/lib/txGuards";
import {robinhood} from "@/lib/wagmi";

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
  // Reads stay pinned to Robinhood Chain whatever chain the wallet is on.
  const publicClient = usePublicClient({chainId: robinhood.id});
  // The quote is stored with the inputs that produced it and only exposed while they still match
  // the current inputs. Without this, the previous quote survived the debounce + RPC round trip
  // after an input change (or a direction flip, where it is in the other token's decimals), so a
  // min-out could be built from stale inputs.
  const [result, setResult] = useState<Keyed<bigint> | undefined>(undefined);

  // CRITICAL: poolKey is a fresh object literal on every parent render, so it can't go into
  // the dep array directly - the effect would re-run on every render, perpetually clearing the
  // debounce timer before it ever fires (this caused the "stuck on quoting" symptom). We derive
  // a stable string id from its fields and depend on that instead.
  const poolKeyId = poolKey
    ? `${poolKey.currency0}|${poolKey.currency1}|${poolKey.fee}|${poolKey.tickSpacing}|${poolKey.hooks}`
    : "";
  const active = !!publicClient && !!router && !!poolKey && !!account && !!amountIn && amountIn > 0n;
  const key = swapQuoteKey({router, poolKeyId, zeroForOne, amountIn, account});

  useEffect(() => {
    if (!active || !publicClient || !router || !poolKey || !account || !amountIn) return;

    let cancelled = false;
    // Debounce: wait 400ms after the last input change before firing the simulate. Stops the
    // RPC flood that used to happen when the user typed an amount character-by-character.
    const timer = setTimeout(() => {
      publicClient
        .simulateContract({
          address: router,
          abi: swapRouterAbi,
          functionName: "swap",
          args: [poolKey, zeroForOne, amountIn, 0n, account, ZERO_BYTES],
          account,
        })
        .then((res) => {
          if (!cancelled) setResult({key, value: res.result as bigint});
        })
        .catch((e) => {
          if (!cancelled) setResult({key, error: extractRevertReason(e)});
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
    quote: active ? current.value : undefined,
    error: active ? current.error : undefined,
    // Loading from the moment inputs change, not only once the debounce fires.
    loading: active && !current.fresh,
  };
}

/** Everything a swap quote depends on. A quote is only valid for the exact key it was made for. */
export function swapQuoteKey({
  router,
  poolKeyId,
  zeroForOne,
  amountIn,
  account,
}: {
  router: string | undefined;
  poolKeyId: string;
  zeroForOne: boolean;
  amountIn: bigint | undefined;
  account: string | undefined;
}): string {
  return inputsKey(router, poolKeyId, zeroForOne, amountIn, account);
}

function extractRevertReason(e: unknown): string {
  const err = e as {shortMessage?: string; message?: string};
  // viem ContractFunctionExecutionError formats nicely in shortMessage. v4 wraps hook reverts
  // (e.g. SwapWouldBreakPool) in WrappedError, which the router ABI cannot decode, so also carry
  // any raw revert data found in the cause chain so the panel can match the hook's selector.
  const short = err.shortMessage ?? err.message ?? "Simulation failed";
  const raw = rawRevertData(e);
  return raw ? `${short} [data ${raw}]` : short;
}

function rawRevertData(e: unknown): string | undefined {
  let cur: unknown = e;
  for (let depth = 0; depth < 8 && cur && typeof cur === "object"; depth++) {
    const node = cur as {data?: unknown; raw?: unknown; cause?: unknown};
    for (const candidate of [node.raw, node.data]) {
      if (typeof candidate === "string" && candidate.startsWith("0x")) return candidate;
      if (candidate && typeof candidate === "object") {
        const nested = (candidate as {data?: unknown}).data;
        if (typeof nested === "string" && nested.startsWith("0x")) return nested;
      }
    }
    cur = node.cause;
  }
  return undefined;
}
