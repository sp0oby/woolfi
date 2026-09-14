"use client";

import {useState} from "react";

import type {CuratedPool} from "@/lib/pools/types";

/**
 * Pending-pool form previews. These render the shape of the action (input + chips + button)
 * disabled, so a visitor can see WHAT they'll be able to do without needing to know that the
 * pool is deployed. When the coordinated launch lands, `TerminalActionRail` swaps these out
 * for the wired panels.
 */

export function PreviewSwap({pool}: {pool: CuratedPool}) {
  const from = pool.base.symbol;
  const to = pool.quote.symbol;
  return (
    <Frame title="Trade" hint="Swap unlocks at coordinated launch.">
      <TokenInput label="From" symbol={from} />
      <SwapChips />
      <SwapDirection />
      <TokenInput label="To (estimated)" symbol={to} readOnly />
      <QuickAmounts />
      <ActionButton>Swap unavailable · pool pending</ActionButton>
      <FeeStrip pool={pool} />
    </Frame>
  );
}

export function PreviewLiquidity({pool}: {pool: CuratedPool}) {
  const [mode, setMode] = useState<"balanced" | "single">("balanced");
  const zapCandidates = ["USDG", "WETH"].filter(
    (s) => s !== pool.base.symbol && s !== pool.quote.symbol,
  );
  return (
    <Frame title="Provide liquidity" hint="Full-range LP mint. Withdrawals always open.">
      <div className="grid grid-cols-2 border border-line p-0.5 font-mono text-micro uppercase tracking-[0.2em]">
        {(["balanced", "single"] as const).map((m) => (
          <button
            key={m}
            type="button"
            onClick={() => setMode(m)}
            className={`px-3 py-1.5 transition-colors ${
              mode === m ? "bg-surface text-ink" : "text-muted hover:text-ink"
            }`}
          >
            {m === "balanced" ? "Balanced" : "Zap · one token"}
          </button>
        ))}
      </div>

      {mode === "balanced" ? (
        <>
          <TokenInput label={pool.base.symbol} symbol={pool.base.symbol} />
          <TokenInput label={pool.quote.symbol} symbol={pool.quote.symbol} />
        </>
      ) : (
        <>
          <TokenInput label="Zap in" symbol={zapCandidates[0] ?? pool.quote.symbol} />
          <div className="border border-line bg-bg px-3 py-2.5 shadow-raised">
            <div className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">
              Auto-split preview
            </div>
            <div className="tabular mt-1 font-mono text-2xs text-ink">
              50% → {pool.base.symbol} &nbsp;·&nbsp; 50% → {pool.quote.symbol}
            </div>
            <div className="mt-1 font-mono text-micro text-subtle">
              Routed through the governance-allowlisted external swap executor. Any dust refunded.
            </div>
          </div>
        </>
      )}

      <QuickAmounts />
      <MiniRow label="Est. LP shares" value="-" />
      <MiniRow label="Base fee" value={`${pool.risk.baseFeeBps} bps`} />
      <MiniRow
        label="Fee split"
        value={`LP ${100 - pool.risk.vaultFeeBps / 100 - pool.risk.treasuryFeeBps / 100}% · Vault ${
          pool.risk.vaultFeeBps / 100
        }% · Trs ${pool.risk.treasuryFeeBps / 100}%`}
      />
      <ActionButton>
        {mode === "single" ? "Zap unavailable · pool pending" : "Provide unavailable · pool pending"}
      </ActionButton>
    </Frame>
  );
}

export function PreviewStake({pool}: {pool: CuratedPool}) {
  return (
    <Frame title="Stake URU" hint="Underwriter earns pool-token fees, bears break drawdown.">
      <TokenInput label="Stake" symbol="URU" />
      <QuickAmounts />
      <MiniRow label="Drawdown on break" value={`${pool.risk.drawdownBps / 100}% of vault`} />
      <MiniRow label="Unstake cooldown" value="7 days" />
      <ActionButton>Stake unavailable · pool pending</ActionButton>
    </Frame>
  );
}

export function PreviewRebate({pool}: {pool: CuratedPool}) {
  return (
    <Frame title="Urufu Gemu rebate" hint="15% of base-fee portion, funded, per-token weekly cap.">
      <MiniRow label="Eligibility" value="Connect wallet · check NFT" />
      <MiniRow label="Rebate rate" value="15% of base-fee portion" />
      <MiniRow label="Pool" value={`${pool.base.symbol} / ${pool.quote.symbol}`} />
      <ActionButton>Claim unavailable · pool pending</ActionButton>
    </Frame>
  );
}

/* ------------------------------ primitives ------------------------------ */

function Frame({title, hint, children}: {title: string; hint: string; children: React.ReactNode}) {
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-baseline justify-between">
        <h3 className="font-display text-[18px] font-medium text-ink">{title}</h3>
        <span className="font-mono text-micro uppercase tracking-[0.2em] text-signal">Preview</span>
      </div>
      <p className="font-mono text-2xs text-muted">{hint}</p>
      {children}
    </div>
  );
}

function TokenInput({
  label,
  symbol,
  readOnly,
}: {
  label: string;
  symbol: string;
  readOnly?: boolean;
}) {
  return (
    <div className="border border-line bg-bg px-3 py-2.5 shadow-raised">
      <div className="flex items-center justify-between">
        <span className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">{label}</span>
        <span className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">
          Balance -
        </span>
      </div>
      <div className="mt-1 flex items-baseline justify-between gap-3">
        <input
          disabled
          readOnly={readOnly}
          placeholder="0.00"
          className="tabular w-0 flex-1 border-none bg-transparent p-0 font-mono text-[22px] font-medium text-ink outline-none placeholder:text-subtle"
        />
        <span className="border border-line bg-surface px-2 py-1 font-mono text-2xs font-medium uppercase tracking-wider text-ink">
          {symbol}
        </span>
      </div>
    </div>
  );
}

function SwapChips() {
  return (
    <div className="flex gap-1">
      {["25%", "50%", "75%", "MAX"].map((s) => (
        <button
          key={s}
          type="button"
          disabled
          className="flex-1 border border-line bg-bg py-1 font-mono text-micro uppercase tracking-wider text-muted hover:bg-surface disabled:cursor-not-allowed"
        >
          {s}
        </button>
      ))}
    </div>
  );
}

function SwapDirection() {
  return (
    <div className="flex justify-center">
      <div className="flex h-6 w-6 items-center justify-center border border-line bg-surface font-mono text-2xs text-muted">
        ↓
      </div>
    </div>
  );
}

function QuickAmounts() {
  return (
    <div className="flex gap-1">
      {["$100", "$500", "$1K", "$5K"].map((s) => (
        <button
          key={s}
          type="button"
          disabled
          className="flex-1 border border-line bg-bg py-1 font-mono text-2xs text-muted hover:bg-surface disabled:cursor-not-allowed"
        >
          {s}
        </button>
      ))}
    </div>
  );
}

function ActionButton({children}: {children: React.ReactNode}) {
  return (
    <button
      type="button"
      disabled
      className="mt-1 w-full cursor-not-allowed border border-line bg-surface py-2.5 font-mono text-2xs uppercase tracking-[0.22em] text-muted"
    >
      {children}
    </button>
  );
}

function MiniRow({label, value}: {label: string; value: string}) {
  return (
    <div className="flex items-baseline justify-between border-b border-line/60 py-1.5 last:border-b-0">
      <span className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">{label}</span>
      <span className="tabular font-mono text-2xs text-ink">{value}</span>
    </div>
  );
}

function FeeStrip({pool}: {pool: CuratedPool}) {
  return (
    <div className="grid grid-cols-3 border border-line divide-x divide-line">
      <FeeCell label="Base" value={`${pool.risk.baseFeeBps} bps`} />
      <FeeCell label="Tol" value={`±${pool.risk.toleranceBps}`} />
      <FeeCell label="Hard" value={`±${pool.risk.hardThresholdBps}`} />
    </div>
  );
}

function FeeCell({label, value}: {label: string; value: string}) {
  return (
    <div className="px-3 py-2 text-center">
      <div className="font-mono text-micro uppercase tracking-[0.2em] text-subtle">{label}</div>
      <div className="tabular mt-0.5 font-mono text-2xs text-ink">{value}</div>
    </div>
  );
}
