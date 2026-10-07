"use client";

import {useMemo, useState} from "react";

import {launchLiquidityCopy} from "@/components/poolState";
import {useSelectedPool} from "@/hooks/useSelectedPool";
import {filterPools} from "@/lib/pools/registry";
import type {CuratedPool, PoolCategory} from "@/lib/pools/types";

const CATEGORIES: readonly {value: "all" | PoolCategory; label: string}[] = [
  {value: "all", label: "All"},
  {value: "stock-usdg", label: "USDG"},
  {value: "stock-weth", label: "WETH"},
  {value: "spread", label: "Sprd"},
  {value: "crypto", label: "Crypto"},
];

export function TerminalPoolRail() {
  const {pool, pools, selectPool} = useSelectedPool();
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<(typeof CATEGORIES)[number]["value"]>("all");

  const visible = useMemo(() => filterPools(pools, query, category), [category, pools, query]);
  // Seeded pools first (they have something to trade against), then the rest in catalog order.
  const sorted = useMemo(
    () => [...visible].sort((a, b) => Number(b.seeded) - Number(a.seeded)),
    [visible],
  );

  return (
    <aside className="flex h-full flex-col border-r border-line bg-panel">
      <div className="border-b border-line px-4 py-3">
        <div className="flex items-center justify-between">
          <span className="font-mono text-2xs uppercase tracking-[0.22em] text-muted">Pools</span>
          <span className="tabular font-mono text-2xs text-subtle">{visible.length}/{pools.length}</span>
        </div>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search…"
          aria-label="Search pools"
          className="mt-2 w-full border border-line bg-bg px-2.5 py-1.5 font-mono text-[13px] text-ink outline-none placeholder:text-subtle focus:border-line-strong"
        />
        <div className="mt-2 flex flex-wrap gap-1">
          {CATEGORIES.map((c) => {
            const active = c.value === category;
            return (
              <button
                key={c.value}
                type="button"
                onClick={() => setCategory(c.value)}
                className={`border px-2 py-0.5 font-mono text-micro uppercase tracking-wider transition-colors ${
                  active
                    ? "border-line-strong bg-surface text-ink"
                    : "border-line text-muted hover:text-ink"
                }`}
              >
                {c.label}
              </button>
            );
          })}
        </div>
      </div>

      <p className="border-b border-line px-4 py-2.5 text-[12px] leading-snug text-muted">
        {launchLiquidityCopy(pools.some((p) => p.status === "live"))}
      </p>

      <div className="flex-1 overflow-y-auto">
        {sorted.length > 0 ? <RailList pools={sorted} activeSlug={pool.slug} onSelect={selectPool} /> : null}
        {visible.length === 0 ? (
          <p className="px-4 py-4 font-mono text-2xs text-muted">No matching pools.</p>
        ) : null}
      </div>
    </aside>
  );
}

function RailList({
  pools,
  activeSlug,
  onSelect,
}: {
  pools: readonly CuratedPool[];
  activeSlug: string;
  onSelect: (slug: string) => void;
}) {
  return (
    <div>
      <ul>
        {pools.map((p) => {
          const selected = p.slug === activeSlug;
          return (
            <li key={p.slug}>
              <button
                type="button"
                onClick={() => onSelect(p.slug)}
                aria-pressed={selected}
                className={`group flex w-full items-center justify-between gap-2 border-l-2 px-4 py-2.5 text-left transition-colors ${
                  selected
                    ? "border-signal bg-surface"
                    : "border-transparent hover:bg-white/[0.02]"
                }`}
              >
                <div className="flex min-w-0 items-center gap-2.5">
                  <StateDot status={p.status} seeded={p.seeded} />
                  <span
                    className={`tabular font-mono text-[13px] ${selected ? "text-ink" : "text-ink/85"}`}
                  >
                    {p.base.symbol}
                    <span className="text-subtle"> / </span>
                    {p.quote.symbol}
                  </span>
                </div>
                <span className="flex items-center gap-2">
                  {p.status === "live" && !p.seeded ? (
                    <span className="border border-warn/40 px-1.5 font-mono text-micro uppercase tracking-wider text-warn">
                      needs LP
                    </span>
                  ) : null}
                  <span className="font-mono text-micro uppercase tracking-wider text-muted">
                    {p.tradingHours === "always-open" ? "24/7" : "eq-hrs"}
                  </span>
                </span>
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function StateDot({status, seeded}: {status: "live" | "pending"; seeded: boolean}) {
  if (status === "live" && !seeded) {
    return <span className="inline-block h-2 w-2 shrink-0 rounded-full border border-warn" />;
  }
  if (status === "live") {
    return (
      <span className="relative inline-flex h-2 w-2 shrink-0">
        <span className="absolute inline-flex h-full w-full rounded-full bg-pos opacity-60 animate-signal-pulse" />
        <span className="relative inline-flex h-2 w-2 rounded-full bg-pos" />
      </span>
    );
  }
  return <span className="inline-block h-2 w-2 shrink-0 rounded-full bg-subtle" />;
}
