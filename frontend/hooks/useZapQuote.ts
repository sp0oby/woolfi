"use client";

import {useEffect, useState} from "react";
import {
  concatHex,
  encodeFunctionData,
  numberToHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import {useChainId, usePublicClient} from "wagmi";

import {pmAbi, uniswapV3QuoterAbi, uniswapV3RouterAbi} from "@/lib/abis";
import {robinhoodAssets} from "@/lib/pools/assets";
import type {PoolKey} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

const QUOTER = "0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7" as const;
const FEES = [500, 3000, 10_000] as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;

export type QuotedSwapPlan = {
  executor: Address;
  tokenOut: Address;
  amountIn: bigint;
  minAmountOut: bigint;
  data: Hex;
};

export type ZapQuote = {
  swap0: QuotedSwapPlan;
  swap1: QuotedSwapPlan;
  shares: bigint;
  amount0: bigint;
  amount1: bigint;
};

type Args = {
  deployment: WoolFiDeployment;
  key: PoolKey;
  tokenIn: Address;
  amountIn: bigint | undefined;
  account: Address | undefined;
  enabled: boolean;
};

export function useZapQuote({deployment, key, tokenIn, amountIn, account, enabled}: Args) {
  const chainId = useChainId();
  const client = usePublicClient({chainId});
  const [quote, setQuote] = useState<ZapQuote>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(false);
  const keyId = `${key.currency0}|${key.currency1}|${key.fee}|${key.tickSpacing}|${key.hooks}`;

  useEffect(() => {
    if (!client || !account || !amountIn || !enabled || !deployment.externalSwapExecutor || !deployment.liquidityZapper) {
      setQuote(undefined);
      setError(undefined);
      setLoading(false);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(() => {
      setLoading(true);
      buildQuote(client, deployment, key, tokenIn, amountIn, account)
        .then((result) => {
          if (!cancelled) {
            setQuote(result);
            setError(undefined);
          }
        })
        .catch((cause: unknown) => {
          if (!cancelled) {
            const failure = cause as {shortMessage?: string; message?: string};
            setQuote(undefined);
            setError(failure.shortMessage ?? failure.message ?? "No executable Uniswap route found");
          }
        })
        .finally(() => {
          if (!cancelled) setLoading(false);
        });
    }, 500);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [client, deployment, keyId, tokenIn, amountIn, account, enabled]);

  return {quote, error, loading};
}

async function buildQuote(
  client: PublicClient,
  deployment: WoolFiDeployment,
  key: PoolKey,
  tokenIn: Address,
  amountIn: bigint,
  account: Address,
): Promise<ZapQuote> {
  const executor = deployment.externalSwapExecutor!;
  const zapper = deployment.liquidityZapper!;
  const amountA = amountIn / 2n;
  const amountB = amountIn - amountA;
  let amount0 = tokenIn.toLowerCase() === deployment.token0.toLowerCase() ? amountB : 0n;
  let amount1 = tokenIn.toLowerCase() === deployment.token1.toLowerCase() ? amountB : 0n;

  const targets =
    tokenIn.toLowerCase() === deployment.token0.toLowerCase()
      ? [[deployment.token1, amountA] as const]
      : tokenIn.toLowerCase() === deployment.token1.toLowerCase()
        ? [[deployment.token0, amountA] as const]
        : [[deployment.token0, amountA] as const, [deployment.token1, amountB] as const];

  const routed = await Promise.all(
    targets.map(async ([tokenOut, swapAmount]) => {
      const route = await bestRoute(client, tokenIn, tokenOut, swapAmount, account);
      const minimum = route.amountOut * 9_900n / 10_000n;
      const plan: QuotedSwapPlan = {
        executor,
        tokenOut,
        amountIn: swapAmount,
        minAmountOut: minimum,
        data: encodeFunctionData({
          abi: uniswapV3RouterAbi,
          functionName: "exactInput",
          args: [{path: route.path, recipient: zapper, amountIn: swapAmount, amountOutMinimum: minimum}],
        }),
      };
      return {plan, amountOut: route.amountOut};
    }),
  );

  for (const item of routed) {
    if (item.plan.tokenOut.toLowerCase() === deployment.token0.toLowerCase()) amount0 += item.amountOut;
    else amount1 += item.amountOut;
  }
  const shares = await client.readContract({
    address: deployment.positionManager,
    abi: pmAbi,
    functionName: "previewMint",
    args: [key, amount0, amount1],
  });
  if (shares === 0n) throw new Error("Quoted routes would mint zero LP shares");
  return {swap0: routed[0]?.plan ?? emptyPlan(), swap1: routed[1]?.plan ?? emptyPlan(), shares, amount0, amount1};
}

async function bestRoute(
  client: PublicClient,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  account: Address,
): Promise<{path: Hex; amountOut: bigint}> {
  const paths: Hex[] = FEES.map((fee) => encodePath([tokenIn, tokenOut], [fee]));
  for (const bridge of [robinhoodAssets.USDG.address, robinhoodAssets.WETH.address]) {
    if (bridge.toLowerCase() === tokenIn.toLowerCase() || bridge.toLowerCase() === tokenOut.toLowerCase()) continue;
    for (const fee0 of FEES) for (const fee1 of FEES) paths.push(encodePath([tokenIn, bridge, tokenOut], [fee0, fee1]));
  }
  const results = await Promise.allSettled(
    paths.map(async (path) => {
      const result = await client.simulateContract({
        address: QUOTER,
        abi: uniswapV3QuoterAbi,
        functionName: "quoteExactInput",
        args: [path, amountIn],
        account,
      });
      return {path, amountOut: result.result[0]};
    }),
  );
  const routes = results.flatMap((result) => result.status === "fulfilled" && result.value.amountOut > 0n ? [result.value] : []);
  if (routes.length === 0) throw new Error("No liquid Uniswap v3 route found for this asset");
  return routes.reduce((best, route) => route.amountOut > best.amountOut ? route : best);
}

function encodePath(tokens: readonly Address[], fees: readonly number[]): Hex {
  const parts: Hex[] = [tokens[0]];
  fees.forEach((fee, index) => parts.push(numberToHex(fee, {size: 3}), tokens[index + 1]));
  return concatHex(parts);
}

function emptyPlan(): QuotedSwapPlan {
  return {executor: ZERO, tokenOut: ZERO, amountIn: 0n, minAmountOut: 0n, data: "0x"};
}
