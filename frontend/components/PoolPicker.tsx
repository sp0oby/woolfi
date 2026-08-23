"use client";

import {useMemo, useState} from "react";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {filterPools} from "@/lib/pools/registry";
import type {PoolCategory} from "@/lib/pools/types";

const filters: readonly {value: "all" | PoolCategory; label: string}[] = [
  {value: "all", label: "All"},
  {value: "stock-usdg", label: "Stock / USDG"},
  {value: "stock-weth", label: "Stock / WETH"},
  {value: "spread", label: "Spreads"},
  {value: "crypto", label: "Crypto"},
];

export function PoolPicker() {
  const {pool, pools, selectPool} = useSelectedPool();
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<(typeof filters)[number]["value"]>("all");

  const visible = useMemo(() => filterPools(pools, query, category), [category, pools, query]);
  const groups = [
    {label: "Live", pools: visible.filter((candidate) => candidate.status === "live")},
    {label: "Coming soon", pools: visible.filter((candidate) => candidate.status === "pending")},
  ] as const;

  return (
    <section className="mt-8 border border-line p-4" aria-label="Select pool">
      <div className="flex flex-col gap-3 sm:flex-row">
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search pools"
          aria-label="Search pools"
          className="min-w-0 flex-1 border border-line bg-transparent px-3 py-2 font-mono text-[12px] text-white outline-none placeholder:text-muted"
        />
        <select
          value={category}
          onChange={(event) => setCategory(event.target.value as typeof category)}
          aria-label="Filter pool category"
          className="border border-line bg-bg px-3 py-2 font-mono text-[11px] uppercase tracking-[0.14em] text-ink outline-none"
        >
          {filters.map((filter) => (
            <option key={filter.value} value={filter.value}>{filter.label}</option>
          ))}
        </select>
      </div>
      <div className="mt-3 max-h-60 space-y-3 overflow-y-auto">
        {groups.map((group) =>
          group.pools.length > 0 ? (
            <div key={group.label}>
              <p className="px-3 pb-1 font-mono text-[9px] uppercase tracking-[0.2em] text-muted">
                {group.label}
              </p>
              <div className="grid grid-cols-1 gap-1 sm:grid-cols-2">
                {group.pools.map((candidate) => {
                  const selected = candidate.slug === pool.slug;
                  return (
                    <button
                      key={candidate.slug}
                      type="button"
                      onClick={() => selectPool(candidate.slug)}
                      aria-pressed={selected}
                      className={`flex items-center justify-between px-3 py-2 text-left font-mono text-[11px] transition-colors ${
                        selected ? "bg-white/[0.07] text-white" : "text-muted hover:bg-white/[0.03] hover:text-ink"
                      }`}
                    >
                      <span>{candidate.base.symbol} / {candidate.quote.symbol}</span>
                      <span className={candidate.status === "live" ? "text-emerald-300" : "text-amber-200/80"}>
                        {candidate.status}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          ) : null,
        )}
        {visible.length === 0 ? (
          <p className="px-3 py-2 font-mono text-[11px] text-muted">No matching pools.</p>
        ) : null}
      </div>
    </section>
  );
}
