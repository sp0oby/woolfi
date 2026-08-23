"use client";

import {usePoolReads} from "@/hooks/usePool";
import {useSelectedPool} from "@/hooks/useSelectedPool";
import {fmtAmount} from "@/lib/format";

/**
 * Compact live read of the deployed pool, intended for the splash page.
 * Same data source as the dashboard's PoolCard - refreshes every 12 s.
 */
export function LivePoolStrip() {
  const {pool} = useSelectedPool();
  const {drift, fairPriceWad, vaultStaked, config, safety, deployment} = usePoolReads();
  const state = safety?.structurallyBroken
    ? "broken"
    : safety?.stabilizing
      ? "stabilizing"
      : safety?.oracleSkewed
        ? "skewed"
        : config
          ? "ok"
          : "-";

  if (!deployment) {
    return (
      <p className="mt-5 font-mono text-[12px] leading-[1.75] text-muted border-l border-line pl-5">
        {pool.base.symbol} / {pool.quote.symbol} is curated and pending deployment on Robinhood Chain.
      </p>
    );
  }

  return (
    <dl className="mt-5 grid grid-cols-2 sm:grid-cols-4 divide-x divide-line border border-line">
      <Cell label="Fair price" value={fmtAmount(fairPriceWad)} />
      <Cell label="Drift (bps)" value={drift !== undefined ? signedBps(drift) : "-"} />
      <Cell label="Vault stake" value={fmtAmount(vaultStaked)} />
      <Cell label="State" value={state} />
    </dl>
  );
}

function Cell({label, value}: {label: string; value: string}) {
  return (
    <div className="px-4 py-3">
      <dt className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">{label}</dt>
      <dd className="mt-1 font-mono text-[14px] text-ink">{value}</dd>
    </div>
  );
}

function signedBps(bps: bigint): string {
  return `${bps > 0n ? "+" : ""}${bps.toString()}`;
}
