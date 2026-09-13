"use client";

import {useSelectedPool} from "@/hooks/useSelectedPool";

import {LiquidityPanel} from "./panels/LiquidityPanel";
import {RebatePanel} from "./panels/RebatePanel";
import {SwapPanel} from "./panels/SwapPanel";
import {VaultPanel} from "./panels/VaultPanel";
import {Tabs} from "./Tabs";

export function DashboardHeading() {
  const {pool} = useSelectedPool();
  const pair = `${pool.base.symbol} / ${pool.quote.symbol}`;
  const status = pool.status === "live"
    ? "Live · Robinhood Chain"
    : `Candidate · ${pool.category.replace("-", " / ")} · deployment pending`;

  return (
    <>
      <h1 className="text-[32px] font-medium tracking-[-0.02em] leading-tight">{pair}</h1>
      <p className="mt-3 font-mono text-[12px] uppercase tracking-[0.22em] text-muted">{status}</p>
    </>
  );
}

export function DashboardTabs() {
  return (
    <Tabs
      tabs={[
        {id: "trade", label: "Trade"},
        {id: "provide", label: "Provide liquidity"},
        {id: "stake", label: "Stake URU"},
        {id: "rebates", label: "NFT rebates"},
      ]}
      panels={{
        trade: <SwapPanel />,
        provide: <LiquidityPanel />,
        stake: <VaultPanel />,
        rebates: <RebatePanel />,
      }}
    />
  );
}
