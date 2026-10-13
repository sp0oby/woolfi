"use client";

import {useChainId, useWaitForTransactionReceipt} from "wagmi";

import {useWrongNetwork} from "@/hooks/useWrongNetwork";
import {MAX_SLIPPAGE_BPS, parseSlippageBps, SLIPPAGE_WARN_BPS} from "@/lib/txGuards";
import {chainNameById, explorerTx, robinhood} from "@/lib/wagmi";

/**
 * Shared atoms for the trade / liquidity / vault panels. Mono labels, bordered boxes,
 * no rounded corners - same vocabulary as the splash so the app reads as one piece.
 */

export function Field({
  label,
  token,
  value,
  onChange,
  editable = false,
  hint,
}: {
  label: string;
  token: string;
  value: string;
  onChange?: (v: string) => void;
  editable?: boolean;
  hint?: string;
}) {
  return (
    <div className="border border-line">
      <div className="px-5 py-3 border-b border-line flex items-baseline justify-between">
        <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">{label}</span>
        {hint ? (
          <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">
            {hint}
          </span>
        ) : null}
      </div>
      <div className="px-5 py-5 flex items-baseline justify-between gap-4">
        {editable ? (
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.00"
            value={value}
            onChange={(e) => onChange?.(e.target.value.replace(/[^0-9.]/g, ""))}
            className="bg-transparent font-mono text-2xl text-white outline-none w-full placeholder:text-muted/60"
          />
        ) : (
          <span className="font-mono text-2xl text-white">{value || "-"}</span>
        )}
        <span className="font-mono text-sm text-white shrink-0">{token}</span>
      </div>
    </div>
  );
}

export function StatRow({stats}: {stats: {label: string; value: string}[]}) {
  return (
    <dl
      className="grid divide-x divide-line border border-line"
      style={{gridTemplateColumns: `repeat(${stats.length}, minmax(0,1fr))`}}
    >
      {stats.map((s) => (
        <div key={s.label} className="px-5 py-3">
          <dt className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">{s.label}</dt>
          <dd className="mt-1 font-mono text-sm text-ink">{s.value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function ActionButton({label, sublabel}: {label: string; sublabel?: string}) {
  return (
    <button
      type="button"
      disabled
      className="block w-full py-3 border border-line font-mono text-[11px] uppercase tracking-[0.22em] text-muted cursor-not-allowed hover:cursor-not-allowed"
    >
      {label}
      {sublabel ? <span className="block mt-1 text-[9px] tracking-[0.18em]">{sublabel}</span> : null}
    </button>
  );
}

export function PanelFootnote({children}: {children: React.ReactNode}) {
  return (
    <p className="font-mono text-[12px] leading-relaxed text-muted">{children}</p>
  );
}

/**
 * Honest transaction status for an in-flight write. Renders nothing until a tx hash exists.
 * After that: short hash, pending/confirmed label, and an explorer link when available.
 */
export function TxStatus({hash}: {hash: `0x${string}` | undefined}) {
  const chainId = useChainId();
  const wait = useWaitForTransactionReceipt({hash, query: {enabled: !!hash}});
  if (!hash) return null;

  const url = explorerTx(chainId, hash);
  const short = `${hash.slice(0, 10)}…${hash.slice(-6)}`;
  const status = wait.isLoading ? "pending" : wait.isSuccess ? "confirmed" : wait.isError ? "failed" : "submitted";

  return (
    <div className="border border-line px-5 py-3 flex items-baseline justify-between font-mono text-[11px] uppercase tracking-[0.22em]">
      <span className="flex items-center gap-2 text-muted">
        {wait.isLoading ? <ThreadLoader /> : null}
        tx {status}
      </span>
      {url ? (
        <a href={url} target="_blank" rel="noreferrer" className="text-white hover:underline">
          {short} ↗
        </a>
      ) : (
        <span className="text-white">{short}</span>
      )}
    </div>
  );
}

/** A short strand being spun: the in-flight indicator for transactions and loads. */
export function ThreadLoader() {
  return <span aria-hidden className="thread-loader align-middle" />;
}

/** Single-line, no-border transaction indicator for compact panels. */
export function TxStatusInline({hash}: {hash: `0x${string}` | undefined}) {
  const chainId = useChainId();
  const wait = useWaitForTransactionReceipt({hash, query: {enabled: !!hash}});
  if (!hash) return null;
  const url = explorerTx(chainId, hash);
  const status = wait.isLoading ? "pending" : wait.isSuccess ? "confirmed" : wait.isError ? "failed" : "submitted";
  const dot = wait.isLoading ? <ThreadLoader /> : wait.isSuccess ? "✓" : wait.isError ? "×" : "·";

  return (
    <a
      href={url ?? "#"}
      target={url ? "_blank" : undefined}
      rel="noreferrer"
      className="mt-2 block font-mono text-[10px] uppercase tracking-[0.18em] text-muted hover:text-white transition-colors truncate"
    >
      {dot} {status} ↗
    </a>
  );
}

/**
 * Shown above the action panels while the wallet is on another chain. Every action button is
 * disabled in that state; this is the one way forward.
 */
export function WrongNetworkNotice() {
  const {wrongNetwork, switching, switchToRobinhood} = useWrongNetwork();
  if (!wrongNetwork) return null;
  return (
    <div className="mb-5 space-y-3 border border-warn/30 bg-warn/[0.05] px-4 py-3 font-mono text-[12px] text-ink/90">
      <div className="text-[10px] uppercase tracking-[0.18em] text-warn">Wrong network</div>
      <p className="normal-case">
        Your wallet is on another chain. Actions are disabled until you switch to {chainNameById[robinhood.id]}.
      </p>
      <button
        type="button"
        disabled={switching}
        onClick={switchToRobinhood}
        className="look-btn block w-full py-3 border border-line font-mono text-[11px] uppercase tracking-[0.22em] text-white hover:bg-white/5 disabled:text-muted disabled:cursor-not-allowed"
      >
        {switching ? "Switching…" : `Switch to ${chainNameById[robinhood.id]}`}
      </button>
    </div>
  );
}

/** Slippage tolerance input (%), capped at 5%, with a visible warning above 1%. */
export function SlippageInput({value, onChange}: {value: string; onChange: (v: string) => void}) {
  const bps = parseSlippageBps(value);
  const capPct = Number(MAX_SLIPPAGE_BPS) / 100;
  return (
    <div className="space-y-2">
      <div className="flex items-baseline justify-between gap-3 border border-line px-5 py-3">
        <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">Slippage (%, max {capPct})</span>
        <input
          type="text"
          inputMode="decimal"
          value={value}
          onChange={(e) => onChange(e.target.value.replace(/[^0-9.]/g, ""))}
          aria-invalid={bps === undefined}
          className="bg-transparent font-mono text-sm text-white outline-none text-right w-24"
        />
      </div>
      {value && bps === undefined ? (
        <p className="font-mono text-[11px] text-danger">Enter a slippage between 0 and {capPct}%.</p>
      ) : bps !== undefined && bps > SLIPPAGE_WARN_BPS ? (
        <p className="font-mono text-[11px] text-warn">
          High slippage: you may receive up to {(Number(bps) / 100).toFixed(2)}% less than quoted.
        </p>
      ) : null}
    </div>
  );
}
