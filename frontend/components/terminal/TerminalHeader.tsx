"use client";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {usePoolReads} from "@/hooks/usePool";
import {fmtAmount} from "@/lib/format";

import {TerminalTourButton} from "./TerminalTour";

export function TerminalHeader() {
  const {pool} = useSelectedPool();
  const {drift, fairPriceWad, config, safety, marketOpen, deployment} = usePoolReads();

  const broken = safety?.structurallyBroken === true || config?.structuralBreak === true;
  const state = deriveState({broken, safety, marketOpen, deployment, pool});
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

type State =
  | "pending"
  | "in-band"
  | "closed"
  | "stabilizing"
  | "skewed"
  | "broken"
  | "paused";

function StatePill({state}: {state: State}) {
  const style: Record<State, {label: string; cls: string; dot: string}> = {
    pending: {label: "Pending", cls: "border-line bg-surface text-muted", dot: "bg-subtle"},
    "in-band": {label: "In band", cls: "border-pos-dim bg-pos-dim/20 text-pos", dot: "bg-pos"},
    closed: {label: "Market closed", cls: "border-warn/40 bg-warn/10 text-warn", dot: "bg-warn"},
    stabilizing: {label: "Stabilizing", cls: "border-warn/40 bg-warn/10 text-warn", dot: "bg-warn"},
    skewed: {label: "Skewed", cls: "border-warn/40 bg-warn/10 text-warn", dot: "bg-warn"},
    broken: {label: "Struct break", cls: "border-danger/50 bg-danger/10 text-danger", dot: "bg-danger"},
    paused: {label: "Paused", cls: "border-danger/50 bg-danger/10 text-danger", dot: "bg-danger"},
  };
  const s = style[state];
  return (
    <span
      className={`inline-flex items-center gap-2 border px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.2em] ${s.cls}`}
    >
      <span className={`inline-block h-1.5 w-1.5 rounded-full ${s.dot} animate-signal-pulse`} />
      {s.label}
    </span>
  );
}

function deriveState(args: {
  broken: boolean;
  safety?: {stabilizing: boolean; oracleSkewed: boolean};
  marketOpen: boolean | undefined;
  deployment: unknown;
  pool: {tradingHours: "always-open" | "equity-hours"};
}): State {
  if (!args.deployment) return "pending";
  if (args.broken) return "broken";
  if (args.safety?.stabilizing) return "stabilizing";
  if (args.safety?.oracleSkewed) return "skewed";
  if (args.pool.tradingHours === "equity-hours" && args.marketOpen === false) return "closed";
  return "in-band";
}
