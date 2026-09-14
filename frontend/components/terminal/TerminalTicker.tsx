"use client";

import {useSelectedPool} from "@/hooks/useSelectedPool";

/**
 * Bottom marquee: pool symbols with placeholder drift indicators. Once pools are live and there
 * is real fair-vs-pool data per row, this becomes a live tick strip. For now it displays the
 * catalog + tolerance/hard settings so the strip is inhabited from day one.
 */
export function TerminalTicker() {
  const {pools} = useSelectedPool();
  const cells = pools.map((p) => ({
    slug: p.slug,
    label: `${p.base.symbol}/${p.quote.symbol}`,
    tol: p.risk.toleranceBps,
    hard: p.risk.hardThresholdBps,
    hours: p.tradingHours,
    status: p.status,
  }));
  // Duplicate list so the CSS marquee loops seamlessly (translate -50% brings us back to start).
  const marquee = [...cells, ...cells];

  return (
    <div className="relative flex h-8 items-center overflow-hidden border-t border-line bg-panel">
      <div className="pointer-events-none absolute inset-y-0 left-0 z-10 w-16 bg-gradient-to-r from-panel to-transparent" />
      <div className="pointer-events-none absolute inset-y-0 right-0 z-10 w-16 bg-gradient-to-l from-panel to-transparent" />
      <div className="flex min-w-max animate-ticker">
        {marquee.map((c, i) => (
          <div
            key={`${c.slug}-${i}`}
            className="flex items-center gap-2 border-r border-line px-5 font-mono text-2xs uppercase tracking-[0.16em]"
          >
            <span className={`h-2 w-2 rounded-full ${c.status === "live" ? "bg-pos" : "bg-subtle"}`} />
            <span className="tabular text-ink">{c.label}</span>
            <span className="text-subtle">±{c.tol}bps</span>
            <span className="text-subtle">{c.hours === "always-open" ? "24/7" : "eq-hrs"}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
