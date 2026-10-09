"use client";

import {useEffect, useState} from "react";

import {derivePoolState, formatCountdown, type PoolStateView, type Tone} from "@/components/poolState";
import {useSelectedPool} from "@/hooks/useSelectedPool";
import {usePoolReads} from "@/hooks/usePool";
import {fmtAmount} from "@/lib/format";

import {TerminalTourButton} from "./TerminalTour";

export function TerminalHeader() {
  const {pool} = useSelectedPool();
  const {drift, fairPriceWad, config, safety, marketOpen, deployment, breakStatus, totalShares} = usePoolReads();
  const now = useNowSeconds();

  const state = derivePoolState({
    pool,
    deployed: !!deployment,
    breakStatus,
    structurallyBroken: safety?.structurallyBroken === true || config?.structuralBreak === true,
    stabilizing: safety?.stabilizing,
    oracleSkewed: safety?.oracleSkewed,
    marketOpen,
    totalShares,
    nowSeconds: now,
  });
  const driftBps = drift !== undefined ? Number(drift) : undefined;
  const driftColor = driftBps === undefined
    ? "text-muted"
    : Math.abs(driftBps) < (config?.toleranceBps ?? deployment?.toleranceBps ?? 500)
      ? "text-ink"
      : driftBps > 0
        ? "text-neg"
        : "text-pos";

  return (
    <div className="flex flex-wrap items-center justify-between gap-x-8 gap-y-3 border-b border-line bg-panel px-6 py-4">
      <div className="flex items-center gap-4">
        <h1 className="tabular font-display text-[34px] font-medium leading-none tracking-tight text-ink">
          {pool.base.symbol}
          <span className="mx-2 text-subtle/70">/</span>
          {pool.quote.symbol}
        </h1>
        <StatePill state={state} />
        <TerminalTourButton />
      </div>

      <div className="flex flex-wrap items-baseline gap-x-6 gap-y-2">
        <Metric label="Fair" value={fmtAmount(fairPriceWad)} muted={!fairPriceWad} />
        <Metric
          label="Drift"
          value={driftBps === undefined ? "-" : `${driftBps > 0 ? "+" : ""}${driftBps} bps`}
          valueClass={driftColor}
          big
        />
        <Metric
          label="Tol"
          value={`± ${config?.toleranceBps ?? deployment?.toleranceBps ?? pool.risk.toleranceBps} bps`}
          muted
        />
        <Metric
          label="Hard"
          value={`± ${config?.hardThresholdBps ?? deployment?.hardThresholdBps ?? pool.risk.hardThresholdBps} bps`}
          muted
        />
        <Metric label="Base fee" value={`${pool.risk.baseFeeBps} bps`} muted />
        <Metric
          label="Hours"
          value={pool.tradingHours === "always-open" ? "24/7" : marketOpen ? "OPEN" : "CLOSED"}
          valueClass={
            pool.tradingHours === "always-open"
              ? "text-ink"
              : marketOpen
                ? "text-pos"
                : "text-warn"
          }
        />
      </div>
    </div>
  );
}

function Metric({
  label,
  value,
  valueClass = "text-ink",
  muted,
  big,
}: {
  label: string;
  value: string;
  valueClass?: string;
  muted?: boolean;
  big?: boolean;
}) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">{label}</span>
      <span
        className={`tabular font-mono ${big ? "text-[15px]" : "text-[13px]"} ${
          muted ? "text-muted" : valueClass
        }`}
      >
        {value}
      </span>
    </div>
  );
}

const TONE: Record<Tone, {cls: string; dot: string}> = {
  muted: {cls: "border-line bg-surface text-muted", dot: "bg-subtle"},
  pos: {cls: "border-pos-dim bg-pos-dim/20 text-pos", dot: "bg-pos"},
  warn: {cls: "border-warn/40 bg-warn/10 text-warn", dot: "bg-warn"},
  danger: {cls: "border-danger/50 bg-danger/10 text-danger", dot: "bg-danger"},
};

function StatePill({state}: {state: PoolStateView}) {
  const s = TONE[state.tone];
  const countdown =
    state.confirmInSeconds !== undefined ? ` · ${formatCountdown(state.confirmInSeconds)}` : "";
  return (
    <span
      title={state.meaning}
      className={`look-pill look-pill-${state.tone} inline-flex items-center gap-2 border px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.2em] ${s.cls}`}
    >
      <span className={`inline-block h-1.5 w-1.5 rounded-full ${s.dot} animate-signal-pulse`} />
      {state.label}
      {countdown}
    </span>
  );
}

/** Wall clock in seconds, ticking once a second, for break countdowns. */
function useNowSeconds(): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);
  return now;
}
