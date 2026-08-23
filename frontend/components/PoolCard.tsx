"use client";

import {DriftBand} from "@/components/DriftBand";
import {usePoolReads} from "@/hooks/usePool";
import {useRoutedFees} from "@/hooks/useRoutedFees";
import {fmtAmount} from "@/lib/format";
import {useSelectedPool} from "@/hooks/useSelectedPool";

export function PoolCard() {
  const {pool} = useSelectedPool();
  const {drift, totalShares, vaultStaked, fairPriceWad, config, safety, deployment} = usePoolReads();
  const {fee0, fee1, stale} = useRoutedFees();
  const broken = safety?.structurallyBroken === true || config?.structuralBreak === true;
  const stateLabel = broken
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
      <div className="mt-10 border border-line px-6 py-5">
        <div className="flex items-center justify-between gap-4 font-mono text-[11px] uppercase tracking-[0.2em]">
          <span className="text-ink">{pool.base.symbol} / {pool.quote.symbol}</span>
          <span className="text-amber-200/85">Pending</span>
        </div>
        <p className="mt-3 text-[13px] leading-relaxed text-muted">{pool.readinessRequirement}</p>
        <p className="mt-3 font-mono text-[10px] uppercase tracking-[0.18em] text-muted">
          {pool.tradingHours.replace("-", " ")} · tick spacing {pool.risk.tickSpacing} · base fee {pool.risk.baseFeeBps} bps
        </p>
      </div>
    );
  }

  return (
    <div className="mt-10 border border-line">
      {broken ? (
        <div className="px-6 py-2 border-b border-line bg-white/[0.03] font-mono text-[11px] uppercase tracking-[0.22em] text-amber-200/90">
          Structural break · corrective-only
        </div>
      ) : safety?.stabilizing ? (
        <div className="px-6 py-2 border-b border-line bg-white/[0.03] font-mono text-[11px] uppercase tracking-[0.22em] text-amber-200/90">
          Opening stabilization
        </div>
      ) : safety?.oracleSkewed ? (
        <div className="px-6 py-2 border-b border-line bg-white/[0.03] font-mono text-[11px] uppercase tracking-[0.22em] text-amber-200/90">
          Oracle skew · flat fee
        </div>
      ) : null}
      <dl className="grid grid-cols-3 divide-x divide-line text-[13px]">
        <StatCell label="Fair price" value={fmtAmount(fairPriceWad)} />
        <StatCell label="Drift (bps)" value={drift !== undefined ? signedBps(drift) : "-"} />
        <StatCell label="LP shares" value={fmtAmount(totalShares)} />
      </dl>
      <DriftBand
        driftBps={drift}
        toleranceBps={config?.toleranceBps ?? deployment?.toleranceBps}
        hardThresholdBps={config?.hardThresholdBps ?? deployment?.hardThresholdBps}
        broken={broken}
      />
      <dl className="grid grid-cols-3 divide-x divide-line text-[13px] border-t border-line">
        <StatCell label="Vault stake" value={fmtAmount(vaultStaked)} />
        <StatCell label="State" value={stateLabel} />
        <StatCell
          label="Recent fees"
          value={
            fee0 === undefined || fee1 === undefined
              ? "-"
              : `${fmtAmount(fee0, 18, 2)} / ${fmtAmount(fee1, 18, 2)}`
          }
          hint={stale ? "indexer behind" : "routed from indexer"}
        />
      </dl>
    </div>
  );
}

function StatCell({label, value, hint}: {label: string; value: string; hint?: string}) {
  return (
    <div className="px-6 py-4">
      <dt className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">{label}</dt>
      <dd className="mt-2 font-mono text-base text-ink">{value}</dd>
      {hint ? <div className="mt-1 font-mono text-[9px] uppercase tracking-[0.18em] text-muted/80">{hint}</div> : null}
    </div>
  );
}

function signedBps(bps: bigint): string {
  const sign = bps > 0n ? "+" : "";
  return `${sign}${bps.toString()}`;
}
