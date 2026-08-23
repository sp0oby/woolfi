"use client";

import {useChainId, useWaitForTransactionReceipt} from "wagmi";
import {explorerTx} from "@/lib/wagmi";

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
      <span className="text-muted">tx {status}</span>
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

/** Single-line, no-border transaction indicator for compact panels. */
export function TxStatusInline({hash}: {hash: `0x${string}` | undefined}) {
  const chainId = useChainId();
  const wait = useWaitForTransactionReceipt({hash, query: {enabled: !!hash}});
  if (!hash) return null;
  const url = explorerTx(chainId, hash);
  const status = wait.isLoading ? "pending" : wait.isSuccess ? "confirmed" : wait.isError ? "failed" : "submitted";
  const dot = wait.isLoading ? "•" : wait.isSuccess ? "✓" : wait.isError ? "×" : "·";

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
