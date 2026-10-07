"use client";

import {useMemo, useState} from "react";
import {useReadContract, useReadContracts, useSimulateContract, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import robinhoodManifest from "@/lib/deployments/robinhood.json";
import {pmAbi} from "@/lib/abis";
import {uniswapV3NpmAbi, v3MigratorAbi} from "@/lib/abis/v3Migrator";
import {UNISWAP_V3_NPM} from "@/lib/constants";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {StatRow, TxStatus} from "../atoms";
import {btnCls} from "../panelHelpers";

const ZERO = "0x0000000000000000000000000000000000000000";
const MAX_SCAN = 50;

/** Migrator address from the receipt-backed manifest; undefined until deployed. */
export function v3MigratorAddress(): `0x${string}` | undefined {
  const raw = (robinhoodManifest as {v3Migrator?: string}).v3Migrator;
  return raw && raw.toLowerCase() !== ZERO ? (raw as `0x${string}`) : undefined;
}

type V3Position = {
  tokenId: bigint;
  fee: number;
  liquidity: bigint;
  owed0: bigint;
  owed1: bigint;
};

/**
 * Move an existing Uniswap v3 position for this pair into WoolFi in one transaction. The NFT stays
 * in the wallet (emptied); uncollected v3 fees come along; whatever the full-range ratio can't use
 * is refunded to the wallet.
 */
export function MigrateMode({
  deployment,
  address,
}: {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
}) {
  const migrator = v3MigratorAddress();
  const key = poolKeyFor(deployment);
  const positions = useV3Positions(address, deployment);
  const [selectedId, setSelectedId] = useState<bigint | undefined>();
  const selected = positions.find((p) => p.tokenId === selectedId) ?? positions[0];
  const selectedTokenId = selected?.tokenId;
  // Fixed per selection so the simulated estimate doesn't refetch on every render.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const deadline = useMemo(() => BigInt(Math.floor(Date.now() / 1_000) + 20 * 60), [selectedTokenId]);

  // Estimate what the withdrawal returns by simulating decreaseLiquidity as the owner.
  const estimate = useSimulateContract({
    address: UNISWAP_V3_NPM,
    abi: uniswapV3NpmAbi,
    functionName: "decreaseLiquidity",
    args: selected
      ? [{tokenId: selected.tokenId, liquidity: selected.liquidity, amount0Min: 0n, amount1Min: 0n, deadline}]
      : undefined,
    account: address,
    query: {enabled: !!address && !!selected && selected.liquidity > 0n},
  });
  const principal = estimate.data?.result as readonly [bigint, bigint] | undefined;
  const out0 = (principal?.[0] ?? 0n) + (selected?.owed0 ?? 0n);
  const out1 = (principal?.[1] ?? 0n) + (selected?.owed1 ?? 0n);

  const preview = useReadContract({
    address: deployment.positionManager,
    abi: pmAbi,
    functionName: "previewMint",
    args: [key, out0, out1],
    query: {enabled: out0 > 0n && out1 > 0n},
  });
  const shares = preview.data as bigint | undefined;

  const approval = useReadContracts({
    contracts: selected && address && migrator
      ? [
          {address: UNISWAP_V3_NPM, abi: uniswapV3NpmAbi, functionName: "getApproved", args: [selected.tokenId]},
          {address: UNISWAP_V3_NPM, abi: uniswapV3NpmAbi, functionName: "isApprovedForAll", args: [address, migrator]},
        ]
      : [],
    query: {enabled: !!selected && !!address && !!migrator, refetchInterval: 4_000},
  });
  const approvedOne = (approval.data?.[0]?.result as string | undefined)?.toLowerCase() === migrator?.toLowerCase();
  const approvedAll = approval.data?.[1]?.result === true;

  const {writeContract: approve, data: approveHash, isPending: approving, error: approveError} = useWriteContract();
  const {writeContract: migrate, data: migrateHash, isPending: migrating, error: migrateError} = useWriteContract();
  const approveReceipt = useWaitForTransactionReceipt({hash: approveHash});
  const migrateReceipt = useWaitForTransactionReceipt({hash: migrateHash});
  const approved = approvedOne || approvedAll || approveReceipt.isSuccess;
  const busy = approving || migrating || approveReceipt.isLoading || migrateReceipt.isLoading;
  const singleSided = !!principal && (out0 === 0n || out1 === 0n);
  const canAct = !!address && !!migrator && !!selected && !busy && !singleSided && (!approved || !!shares);

  function submit() {
    if (!address || !migrator || !selected) return;
    if (!approved) {
      approve({address: UNISWAP_V3_NPM, abi: uniswapV3NpmAbi, functionName: "approve", args: [migrator, selected.tokenId]});
      return;
    }
    if (!shares) return;
    migrate({
      address: migrator,
      abi: v3MigratorAbi,
      functionName: "migrate",
      args: [{
        tokenId: selected.tokenId,
        woolfiKey: key,
        liquidity: 0n,
        amount0Min: (principal?.[0] ?? 0n) * 9_900n / 10_000n,
        amount1Min: (principal?.[1] ?? 0n) * 9_900n / 10_000n,
        minShares: shares * 9_900n / 10_000n,
        deadline: BigInt(Math.floor(Date.now() / 1_000) + 20 * 60),
        recipient: address,
      }],
    });
  }

  const error = firstError(approveError, migrateError);
  return (
    <>
      {!migrator ? (
        <div className="border border-line px-5 py-4 text-[13px] leading-relaxed text-muted">
          Migration activates once the v3 migrator is receipt-verified in the production manifest.
        </div>
      ) : null}

      {address && positions.length === 0 ? (
        <div className="border border-line px-5 py-4 text-[13px] leading-relaxed text-muted">
          No Uniswap v3 {deployment.token0Symbol}/{deployment.token1Symbol} positions found in this wallet.
        </div>
      ) : null}

      {positions.length > 0 ? (
        <label className="block font-mono text-[10px] uppercase tracking-[0.18em] text-muted">
          Uniswap v3 position
          <select
            value={selected?.tokenId.toString()}
            onChange={(event) => setSelectedId(BigInt(event.target.value))}
            className="mt-2 w-full border border-line bg-black px-3 py-3 text-[12px] text-white"
          >
            {positions.map((p) => (
              <option key={p.tokenId.toString()} value={p.tokenId.toString()}>
                #{p.tokenId.toString()} · {(p.fee / 10_000).toFixed(2)}% fee tier
              </option>
            ))}
          </select>
        </label>
      ) : null}

      <StatRow stats={[
        {label: `${deployment.token0Symbol} out`, value: fmtAmount(principal ? out0 : undefined, deployment.token0Decimals)},
        {label: `${deployment.token1Symbol} out`, value: fmtAmount(principal ? out1 : undefined, deployment.token1Decimals)},
        {label: "Est. WoolFi shares", value: fmtAmount(shares)},
      ]} />

      {singleSided ? (
        <div className="border border-amber-200/30 bg-amber-200/[0.04] px-4 py-3 font-mono text-[12px] text-amber-100/95">
          This position is out of range and holds only one token. WoolFi pools are full-range, so it
          needs both. Withdraw on Uniswap and use Zap instead.
        </div>
      ) : null}
      {error ? (
        <div className="border border-amber-200/30 bg-amber-200/[0.04] px-4 py-3 font-mono text-[12px] text-amber-100/95 break-words">
          {error.slice(0, 320)}
        </div>
      ) : null}

      <button type="button" disabled={!canAct} onClick={submit} className={btnCls(!canAct)}>
        {!address
          ? "Connect wallet"
          : !migrator
            ? "Migrator not deployed"
            : !selected
              ? "No v3 position"
              : singleSided
                ? "Position out of range"
                : !approved
                  ? approving || approveReceipt.isLoading ? "Approving position…" : `Approve position #${selected.tokenId}`
                  : migrating || migrateReceipt.isLoading
                    ? "Migrating…"
                    : "Migrate to WoolFi"}
      </button>
      <TxStatus hash={migrateHash ?? approveHash} />
      <p className="font-mono text-[10px] leading-relaxed text-muted">
        Removes the position from Uniswap v3, collects its uncollected fees, and deposits into this
        full-range WoolFi pool in one transaction. v3 positions are concentrated, so the ratio rarely
        matches exactly: whatever WoolFi can&apos;t use is refunded to your wallet. The NFT stays with
        you, emptied. 1% slippage bounds and a 20-minute deadline apply.
      </p>
    </>
  );
}

/** Wallet's v3 positions for this pair (first MAX_SCAN NFTs), with liquidity or uncollected fees. */
function useV3Positions(owner: `0x${string}` | undefined, deployment: WoolFiDeployment): V3Position[] {
  const balance = useReadContract({
    address: UNISWAP_V3_NPM,
    abi: uniswapV3NpmAbi,
    functionName: "balanceOf",
    args: owner ? [owner] : undefined,
    query: {enabled: !!owner},
  });
  const count = Math.min(Number((balance.data as bigint | undefined) ?? 0n), MAX_SCAN);
  const ids = useReadContracts({
    contracts: owner
      ? Array.from({length: count}, (_, i) => ({
          address: UNISWAP_V3_NPM,
          abi: uniswapV3NpmAbi,
          functionName: "tokenOfOwnerByIndex" as const,
          args: [owner, BigInt(i)] as const,
        }))
      : [],
    query: {enabled: !!owner && count > 0},
  });
  const tokenIds = (ids.data ?? []).map((r) => r.result as bigint | undefined).filter((x): x is bigint => x !== undefined);
  const details = useReadContracts({
    contracts: tokenIds.map((tokenId) => ({
      address: UNISWAP_V3_NPM,
      abi: uniswapV3NpmAbi,
      functionName: "positions" as const,
      args: [tokenId] as const,
    })),
    query: {enabled: tokenIds.length > 0},
  });
  const t0 = deployment.token0.toLowerCase();
  const t1 = deployment.token1.toLowerCase();
  return (details.data ?? []).flatMap((r, i) => {
    const p = r.result as readonly unknown[] | undefined;
    if (!p) return [];
    const [a, b] = [String(p[2]).toLowerCase(), String(p[3]).toLowerCase()];
    const liquidity = p[7] as bigint;
    const owed0 = p[10] as bigint;
    const owed1 = p[11] as bigint;
    const pairMatches = (a === t0 && b === t1) || (a === t1 && b === t0);
    if (!pairMatches || (liquidity === 0n && owed0 === 0n && owed1 === 0n)) return [];
    return [{tokenId: tokenIds[i], fee: Number(p[4]), liquidity, owed0, owed1}];
  });
}

function firstError(...errors: Array<Error | null>): string | undefined {
  const error = errors.find(Boolean) as (Error & {shortMessage?: string}) | undefined;
  return error?.shortMessage ?? error?.message;
}
