"use client";

import {useAccount} from "wagmi";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {usePoolReads, useUserReads} from "@/hooks/usePool";
import {fmtAmount} from "@/lib/format";

/**
 * Bottom half of the right rail. Always visible. Answers "what do I have here right now?" -
 * wallet balances, LP shares, staked URU, pending fees/rewards. When wallet is not connected
 * or pool is pending it degrades gracefully.
 */
export function TerminalPositionCard() {
  const {pool} = useSelectedPool();
  const {address} = useAccount();
  const {deployment, totalShares, vaultStaked} = usePoolReads();
  const user = useUserReads(address);

  const bal0 = user.bal0;
  const bal1 = user.bal1;
  const lpShares = user.lpShares;
  const vaultStake = user.vaultStake;
  const pendingLp = user.pendingLpFees;
  const pendingRewards = user.pendingRewards;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-baseline justify-between">
        <h3 className="font-display text-[16px] font-medium text-ink">Position</h3>
        <span className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">
          {pool.base.symbol}/{pool.quote.symbol}
        </span>
      </div>

      <div className="grid grid-cols-2 gap-px overflow-hidden bg-line shadow-raised">
        <Cell label={`Wallet ${pool.base.symbol}`} value={fmtAmount(bal0, pool.base.decimals)} />
        <Cell label={`Wallet ${pool.quote.symbol}`} value={fmtAmount(bal1, pool.quote.decimals)} />
        <Cell label="LP shares" value={fmtAmount(lpShares)} />
        <Cell label="URU staked" value={fmtAmount(vaultStake)} />
        <Cell
          label="Pending LP fees"
          value={
            pendingLp
              ? `${fmtAmount(pendingLp[0], pool.base.decimals, 2)} / ${fmtAmount(pendingLp[1], pool.quote.decimals, 2)}`
              : "-"
          }
          span
        />
        <Cell
          label="Pending vault rewards"
          value={
            pendingRewards
              ? `${fmtAmount(pendingRewards[0], pool.base.decimals, 2)} / ${fmtAmount(pendingRewards[1], pool.quote.decimals, 2)}`
              : "-"
          }
          span
        />
      </div>

      <div className="flex items-baseline justify-between border-t border-line pt-3">
        <span className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">Pool totals</span>
        <span className="tabular font-mono text-micro text-muted">
          LP {fmtAmount(totalShares)} · URU {fmtAmount(vaultStaked)}
        </span>
      </div>

      {!address ? (
        <div className="mt-1 border border-line bg-surface px-3 py-2 font-mono text-2xs uppercase tracking-[0.18em] text-muted">
          Connect wallet to load your position
        </div>
      ) : !deployment ? (
        <div className="mt-1 border border-line bg-surface px-3 py-2 font-mono text-2xs uppercase tracking-[0.18em] text-muted">
          Pool pending · balances shown when live
        </div>
      ) : null}
    </div>
  );
}

function Cell({label, value, span}: {label: string; value: string; span?: boolean}) {
  return (
    <div className={`bg-panel p-2.5 ${span ? "col-span-2" : ""}`}>
      <div className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">{label}</div>
      <div className="tabular mt-1 font-mono text-2xs text-ink">{value}</div>
    </div>
  );
}
