"use client";

import {useReadContract, useReadContracts} from "wagmi";

import {erc20Abi, hookAbi, marketHoursAbi, oracleAbi, pmAbi, vaultAbi} from "@/lib/abis";
import {WAD} from "@/lib/constants";
import {poolKeyFor, type PoolKey} from "@/lib/poolKey";
import {useSelectedPool} from "./useSelectedPool";

/**
 * Live pool-level reads from chain - drift, structural-break state, vault TVL, PM total shares,
 * oracle fair price. Returns `null` (deployment) when no deployment exists for the active chain.
 */
export function usePoolReads() {
  const {pool, deployment} = useSelectedPool();

  const key = deployment ? poolKeyFor(deployment) : undefined;
  const poolId = deployment?.poolId;

  const reads = useReadContracts({
    contracts: deployment
      ? [
          {address: deployment.hook, abi: hookAbi, functionName: "currentDrift", args: [key as PoolKey]},
          {address: deployment.hook, abi: hookAbi, functionName: "poolConfig", args: [poolId as `0x${string}`]},
          {address: deployment.hook, abi: hookAbi, functionName: "poolSafetyStatus", args: [key as PoolKey]},
          {address: deployment.positionManager, abi: pmAbi, functionName: "totalShares", args: [BigInt(poolId!)]},
          {address: deployment.vault, abi: vaultAbi, functionName: "totalStaked"},
          {address: deployment.vault, abi: vaultAbi, functionName: "totalShares"},
          {address: deployment.oracle0, abi: oracleAbi, functionName: "getPrice"},
          {address: deployment.oracle1, abi: oracleAbi, functionName: "getPrice"},
        ]
      : [],
    query: {enabled: !!deployment, refetchInterval: 12_000},
  });
  const marketHours = useReadContract({
    address: deployment?.marketHours,
    abi: marketHoursAbi,
    functionName: "isMarketOpen",
    query: {
      enabled: !!deployment && pool.tradingHours === "equity-hours",
      refetchInterval: 12_000,
    },
  });

  if (!deployment) return {deployment: null} as const;

  const [drift, config, safety, totalShares, vaultStaked, vaultShares, p0, p1] = (reads.data ?? []) as Array<{
    result?: any;
    error?: Error;
  }>;
  const safetyResult = safety?.result as readonly [boolean, bigint, boolean, boolean] | undefined;

  const price0 = p0?.result as bigint | undefined;
  const price1 = p1?.result as bigint | undefined;
  const fairPriceWad = price0 !== undefined && price1 !== undefined && price1 !== 0n
    ? (price0 * WAD) / price1
    : undefined;

  return {
    deployment,
    isLoading: reads.isLoading,
    drift: drift?.result as bigint | undefined,
    config: config?.result as
      | {
          structuralBreak: boolean;
          configured: boolean;
          toleranceBps: number;
          hardThresholdBps: number;
          cachedFairPriceWad: bigint;
          stabilizationSeconds: number;
          maxOracleSkew: number;
        }
      | undefined,
    safety: safetyResult
      ? {
          structurallyBroken: safetyResult[0],
          cachedFairPriceWad: safetyResult[1],
          stabilizing: safetyResult[2],
          oracleSkewed: safetyResult[3],
        }
      : undefined,
    totalShares: totalShares?.result as bigint | undefined,
    vaultStaked: vaultStaked?.result as bigint | undefined,
    vaultShares: vaultShares?.result as bigint | undefined,
    price0,
    price1,
    fairPriceWad,
    /** `true` when the equity-hours oracle reports the underlying market is open. */
    marketOpen: pool.tradingHours === "always-open" ? true : marketHours.data,
    refetch: reads.refetch,
  } as const;
}

/**
 * Per-user reads: pool and staking-token balances, LP shares, vault stake, pending fees and rewards.
 * Returns sensible undefined values when wallet not connected.
 */
export function useUserReads(account: `0x${string}` | undefined) {
  const {deployment} = useSelectedPool();

  const enabled = !!deployment && !!account;

  const reads = useReadContracts({
    contracts:
      enabled && deployment && account
        ? [
            {address: deployment.token0, abi: erc20Abi, functionName: "balanceOf", args: [account]},
            {address: deployment.token1, abi: erc20Abi, functionName: "balanceOf", args: [account]},
            {address: deployment.stakingToken, abi: erc20Abi, functionName: "balanceOf", args: [account]},
            {address: deployment.positionManager, abi: pmAbi, functionName: "balanceOf", args: [account, BigInt(deployment.poolId)]},
            {address: deployment.vault, abi: vaultAbi, functionName: "sharesOf", args: [account]},
            {address: deployment.vault, abi: vaultAbi, functionName: "pendingRewards", args: [account]},
            {address: deployment.vault, abi: vaultAbi, functionName: "pendingUnstake", args: [account]},
            {address: deployment.positionManager, abi: pmAbi, functionName: "pendingFees", args: [poolKeyFor(deployment), account]},
          ]
        : [],
    query: {enabled, refetchInterval: 12_000},
  });

  const [t0, t1, stakingToken, lp, stake, rewards, unstake, lpFees] = (reads.data ?? []) as Array<{result?: any}>;

  return {
    enabled,
    isLoading: reads.isLoading,
    bal0: t0?.result as bigint | undefined,
    bal1: t1?.result as bigint | undefined,
    stakingTokenBal: stakingToken?.result as bigint | undefined,
    lpShares: lp?.result as bigint | undefined,
    vaultStake: stake?.result as bigint | undefined,
    pendingRewards: rewards?.result as readonly [bigint, bigint] | undefined,
    pendingUnstake: unstake?.result as readonly [bigint, bigint] | undefined,
    pendingLpFees: lpFees?.result as readonly [bigint, bigint] | undefined,
    refetch: reads.refetch,
  } as const;
}

/** Read a single ERC-20 allowance - used by the panels' approval flow. Polls every 4 s as a
 *  belt-and-suspenders alongside the explicit refetch() on a confirmed approval receipt.
 */
export function useAllowance(
  token: `0x${string}` | undefined,
  owner: `0x${string}` | undefined,
  spender: `0x${string}` | undefined,
) {
  return useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: owner && spender ? [owner, spender] : undefined,
    query: {enabled: !!token && !!owner && !!spender, refetchInterval: 4_000},
  });
}
