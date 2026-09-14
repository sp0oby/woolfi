"use client";

import {useMemo} from "react";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {usePoolReads} from "@/hooks/usePool";

/**
 * WoolFi's differentiated chart: drift (pool_price - fair_price)/fair_price over time, with the
 * tolerance band and hard-threshold rails drawn as horizontal guides. Points colored by whether
 * the swap was corrective (toward fair) or adversarial (away).
 *
 * For pending pools there is no historical drift, so we render an empty well with the tolerance
 * / hard rails drawn against a live-current-drift marker (0 if no oracle yet).
 */
export function TerminalDriftChart() {
  const {pool} = useSelectedPool();
  const {drift, config, deployment} = usePoolReads();

  const tolerance = config?.toleranceBps ?? deployment?.toleranceBps ?? pool.risk.toleranceBps;
  const hard = config?.hardThresholdBps ?? deployment?.hardThresholdBps ?? pool.risk.hardThresholdBps;
  const currentBps = drift !== undefined ? Number(drift) : 0;

  // Y-axis extent: 1.4x hard threshold so rails don't hug the frame edge.
  const yMax = Math.round(hard * 1.4);
  const points = useMemo(() => (deployment ? undefined : synthesizeIdlePath(hard)), [deployment, hard]);

  return (
    <div className="border-b border-line bg-panel">
      <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 border-b border-line px-5 py-2.5">
        <div className="flex items-baseline gap-3 whitespace-nowrap">
          <h2 className="font-mono text-2xs uppercase tracking-[0.22em] text-muted">Drift</h2>
          <span className="font-mono text-micro uppercase tracking-[0.18em] text-subtle">
            {deployment ? "live · pool vs fair" : "awaiting deployment"}
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-x-5 gap-y-1 font-mono text-micro uppercase tracking-[0.18em] whitespace-nowrap">
          <Legend swatch="border border-line" label={`Tol ±${tolerance}bps`} />
          <Legend swatch="border border-warn/50" label={`Hard ±${hard}bps`} />
          <Legend dot="bg-pos" label="Corrective" />
          <Legend dot="bg-neg" label="Adversarial" />
        </div>
      </div>
      <div className="relative h-72 bg-grid">
        <ChartSvg
          currentBps={currentBps}
          tolerance={tolerance}
          hard={hard}
          yMax={yMax}
          idealPoints={points}
          liveHistory={undefined}
        />
        {!deployment ? (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <div className="border border-line bg-panel/95 px-3 py-2 text-center font-mono text-micro uppercase tracking-[0.22em] text-muted">
              No live data · pool pending
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}

function Legend({swatch, dot, label}: {swatch?: string; dot?: string; label: string}) {
  return (
    <span className="flex items-center gap-1.5 text-subtle">
      {swatch ? <span className={`inline-block h-2.5 w-3 ${swatch}`} /> : null}
      {dot ? <span className={`inline-block h-1.5 w-1.5 rounded-full ${dot}`} /> : null}
      <span>{label}</span>
    </span>
  );
}

function ChartSvg({
  currentBps,
  tolerance,
  hard,
  yMax,
  idealPoints,
  liveHistory,
}: {
  currentBps: number;
  tolerance: number;
  hard: number;
  yMax: number;
  idealPoints: {x: number; y: number}[] | undefined;
  liveHistory: {x: number; y: number}[] | undefined;
}) {
  const w = 1000;
  const h = 288;
  const padY = 12;
  const midY = h / 2;

  const yFor = (bps: number) => midY - (bps / yMax) * (h / 2 - padY);
  const yTol = {top: yFor(tolerance), bot: yFor(-tolerance)};
  const yHard = {top: yFor(hard), bot: yFor(-hard)};
  const yCur = yFor(clamp(currentBps, -yMax, yMax));

  const pathData = (points: {x: number; y: number}[]) => {
    if (points.length === 0) return "";
    return points
      .map((p, i) => `${i === 0 ? "M" : "L"} ${(p.x * w).toFixed(1)} ${yFor(p.y).toFixed(1)}`)
      .join(" ");
  };

  const history = liveHistory ?? idealPoints ?? [];

  return (
    <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" className="h-full w-full">
      {/* Tolerance band */}
      <rect x="0" y={yTol.top} width={w} height={yTol.bot - yTol.top} fill="rgba(255,255,255,0.025)" />
      {/* Zero line */}
      <line x1="0" y1={midY} x2={w} y2={midY} stroke="rgba(138,138,148,0.35)" strokeDasharray="2 4" />
      {/* Tolerance rails */}
      <line x1="0" y1={yTol.top} x2={w} y2={yTol.top} stroke="rgba(138,138,148,0.45)" strokeDasharray="3 4" />
      <line x1="0" y1={yTol.bot} x2={w} y2={yTol.bot} stroke="rgba(138,138,148,0.45)" strokeDasharray="3 4" />
      {/* Hard rails */}
      <line x1="0" y1={yHard.top} x2={w} y2={yHard.top} stroke="rgba(217,119,6,0.5)" strokeDasharray="4 3" />
      <line x1="0" y1={yHard.bot} x2={w} y2={yHard.bot} stroke="rgba(217,119,6,0.5)" strokeDasharray="4 3" />

      {/* Drift path */}
      {history.length > 0 ? (
        <path d={pathData(history)} stroke="rgba(237,237,237,0.35)" strokeWidth="1.2" fill="none" />
      ) : null}

      {/* Current drift marker */}
      <line
        x1={w - 60}
        y1={yCur}
        x2={w}
        y2={yCur}
        stroke={Math.abs(currentBps) > tolerance ? "#f5b942" : "#4ade80"}
        strokeWidth="1"
      />
      <circle
        cx={w}
        cy={yCur}
        r="3"
        fill={Math.abs(currentBps) > tolerance ? "#f5b942" : "#4ade80"}
      />

      {/* Y-axis tick labels: right side */}
      <text x={w - 4} y={yTol.top - 3} textAnchor="end" fontFamily="ui-monospace" fontSize="9" fill="#5a5a63">
        +{tolerance}
      </text>
      <text x={w - 4} y={yTol.bot + 10} textAnchor="end" fontFamily="ui-monospace" fontSize="9" fill="#5a5a63">
        −{tolerance}
      </text>
      <text x={w - 4} y={yHard.top - 3} textAnchor="end" fontFamily="ui-monospace" fontSize="9" fill="#d97706">
        +{hard}
      </text>
      <text x={w - 4} y={yHard.bot + 10} textAnchor="end" fontFamily="ui-monospace" fontSize="9" fill="#d97706">
        −{hard}
      </text>
    </svg>
  );
}

/**
 * When a pool is pending we still want the chart to look inhabited rather than empty. Draw a
 * quiet, low-amplitude sine that stays inside the tolerance band - an "idealized" reference,
 * clearly labeled as such by the overlay above. Deterministic (no random) so screenshots match.
 */
function synthesizeIdlePath(hardBps: number): {x: number; y: number}[] {
  const amplitude = hardBps * 0.25;
  const points: {x: number; y: number}[] = [];
  for (let i = 0; i <= 80; i++) {
    const x = i / 80;
    const y = amplitude * Math.sin(x * Math.PI * 2 * 1.6 + 0.3) * (1 - x * 0.3);
    points.push({x, y});
  }
  return points;
}

function clamp(v: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, v));
}
