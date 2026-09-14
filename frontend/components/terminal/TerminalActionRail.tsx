"use client";

import {useState} from "react";

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

  return (
    <aside className="flex h-full flex-col border-l border-line bg-panel">
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

      {/* Top half - the action panel (real when live, preview when pending) */}
      <div className="min-h-0 flex-[1_1_60%] overflow-y-auto border-b border-line p-5">
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

      {/* Bottom half - always visible: position + pool overview */}
      <div className="min-h-0 flex-[1_1_40%] overflow-y-auto p-5">
        <TerminalPositionCard />
      </div>
    </aside>
  );
}
