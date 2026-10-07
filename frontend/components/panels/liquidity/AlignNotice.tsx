"use client";

import {useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {poolAlignerAbi} from "@/lib/abis/poolAligner";
import {needsAlign} from "@/lib/poolAligner";
import {poolKeyFor} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {TxStatus} from "../atoms";
import {btnCls} from "../panelHelpers";

/**
 * An empty pool keeps its launch price while Chainlink moves, and the hook refuses deposits once
 * the pool is outside the tolerance band. Before the first deposit, anyone can sync the empty pool
 * to the Chainlink price through the aligner: one transaction, no tokens move.
 */
export function AlignNotice({
  deployment,
  address,
  drift,
  totalShares,
}: {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
  drift: bigint | undefined;
  totalShares: bigint | undefined;
}) {
  const {writeContract, data: hash, isPending, error} = useWriteContract();
  const wait = useWaitForTransactionReceipt({hash, query: {enabled: !!hash}});

  // PositionManager shares are the only route to pool liquidity once it is wired, so zero shares
  // means zero liquidity. Unknown share count: stay quiet rather than guess.
  const show =
    totalShares !== undefined &&
    needsAlign({
      liquidity: totalShares,
      driftBps: drift,
      alignerDeployed: !!deployment.poolAligner,
    });
  if (!show && !hash) return null;

  const done = wait.isSuccess;
  const busy = isPending || wait.isLoading;

  return (
    <div className="border border-line p-4 space-y-3">
      <div className="font-mono text-[10px] uppercase tracking-[0.22em] text-signal">Empty pool · sync price first</div>
      <p className="text-[13px] leading-relaxed text-muted">
        {done
          ? "Synced. The pool now sits on the Chainlink price, so your deposit sets a fair starting ratio."
          : `This pool has no liquidity yet and its price is ${fmtDrift(drift)} off Chainlink. Sync it to the Chainlink price before the first deposit. It is one transaction, costs only gas, and no tokens move. If the pool shows a structural break, it unlocks shortly after syncing.`}
      </p>
      {!done ? (
        <button
          type="button"
          disabled={!address || busy}
          onClick={() =>
            writeContract({
              address: deployment.poolAligner!,
              abi: poolAlignerAbi,
              functionName: "align",
              args: [poolKeyFor(deployment)],
            })
          }
          className={btnCls(!address || busy)}
        >
          {!address ? "Connect wallet to sync" : busy ? "Syncing…" : "Sync to Chainlink price"}
        </button>
      ) : null}
      {error ? <p className="font-mono text-[11px] text-danger">{error.message.split("\n")[0]}</p> : null}
      <TxStatus hash={hash} />
    </div>
  );
}

function fmtDrift(drift: bigint | undefined): string {
  if (drift === undefined) return "some way";
  const bps = drift < 0n ? -drift : drift;
  return `${(Number(bps) / 100).toFixed(2)}%`;
}
