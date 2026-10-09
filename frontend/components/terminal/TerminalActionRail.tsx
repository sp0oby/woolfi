"use client";

import {useEffect, useState} from "react";

import {LiquidityPanel} from "@/components/panels/LiquidityPanel";
import {RebatePanel} from "@/components/panels/RebatePanel";
import {SwapPanel} from "@/components/panels/SwapPanel";
import {VaultPanel} from "@/components/panels/VaultPanel";
import {useSelectedPool} from "@/hooks/useSelectedPool";

import {TerminalPositionCard} from "./TerminalPositionCard";
import {
  PreviewLiquidity,
  PreviewRebate,
  PreviewStake,
  PreviewSwap,
} from "./PendingActionPreview";

type TabId = "trade" | "provide" | "stake" | "rebate";

const TABS: readonly {id: TabId; label: string}[] = [
  {id: "trade", label: "Trade"},
  {id: "provide", label: "Liquidity"},
  {id: "stake", label: "Stake"},
  {id: "rebate", label: "Rebate"},
];

export function TerminalActionRail() {
  const {pool} = useSelectedPool();
  const [active, setActive] = useState<TabId>("trade");
  const pending = pool.status === "pending";

  // Other panels (e.g. the swap panel on an unseeded pool) can ask for a tab switch.
  useEffect(() => {
    function onOpen(e: Event) {
      const tab = (e as CustomEvent<TabId>).detail;
      if (TABS.some((t) => t.id === tab)) setActive(tab);
    }
    window.addEventListener("woolfi:open-tab", onOpen);
    return () => window.removeEventListener("woolfi:open-tab", onOpen);
  }, []);

  return (
    <aside className="slab flex h-full min-h-0 flex-col">
      <div role="tablist" className="grid grid-cols-4 border-b border-line">
        {TABS.map((t) => {
          const isActive = active === t.id;
          return (
            <button
              key={t.id}
              type="button"
              role="tab"
              aria-selected={isActive}
              onClick={() => setActive(t.id)}
              className={`border-r border-line px-3 py-3 font-mono text-2xs uppercase tracking-[0.22em] transition-colors last:border-r-0 ${
                isActive
                  ? "bg-surface text-ink"
                  : "text-muted hover:bg-white/[0.02] hover:text-ink"
              }`}
            >
              {t.label}
            </button>
          );
        })}
      </div>

      {/* One scroll column so the glass action card is never cut by a split scroll boundary. */}
      <div className="min-h-0 flex-1 overflow-y-auto">
        {/* Action panel (real when live, preview when pending) */}
        <div className="p-3">
          <div className="glass-card p-5">
            {pending ? (
              active === "trade" ? (
                <PreviewSwap pool={pool} />
              ) : active === "provide" ? (
                <PreviewLiquidity pool={pool} />
              ) : active === "stake" ? (
                <PreviewStake pool={pool} />
              ) : (
                <PreviewRebate pool={pool} />
              )
            ) : active === "trade" ? (
              <SwapPanel />
            ) : active === "provide" ? (
              <LiquidityPanel />
            ) : active === "stake" ? (
              <VaultPanel />
            ) : (
              <RebatePanel />
            )}
          </div>
        </div>

        {/* Position + pool overview */}
        <div className="px-5 pb-5 pt-2">
          <TerminalPositionCard />
        </div>
      </div>
    </aside>
  );
}
