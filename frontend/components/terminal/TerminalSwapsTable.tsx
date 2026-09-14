"use client";

import {useChainId} from "wagmi";

import {useHookSwaps} from "@/hooks/useHookSwaps";
import {explorerTx} from "@/lib/wagmi";

export function TerminalSwapsTable() {
  const chainId = useChainId();
  const {newest, loading, error, stale, deployment} = useHookSwaps();

  const rows = deployment ? newest?.slice(0, 30) : undefined;

  return (
    <section className="bg-panel">
      <div className="flex items-center justify-between border-b border-line px-5 py-2">
        <div className="flex items-baseline gap-3">
          <h2 className="font-mono text-2xs uppercase tracking-[0.22em] text-muted">Recent swaps</h2>
          {stale ? (
            <span className="font-mono text-micro uppercase tracking-[0.18em] text-warn">indexer stale</span>
          ) : null}
        </div>
        <span className="font-mono text-micro uppercase tracking-[0.18em] text-subtle">
          SwapProcessed events
        </span>
      </div>

      {!deployment ? (
        <EmptyRow msg="No deployment for this chain." />
      ) : error ? (
        <EmptyRow msg={error.message.slice(0, 120)} tone="warn" />
      ) : !rows ? (
        <EmptyRow msg={loading ? "Loading…" : "-"} />
      ) : rows.length === 0 ? (
        <EmptyRow msg="No swaps in the scan window." />
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] border-separate border-spacing-0 text-2xs">
            <thead>
              <tr className="bg-surface/60 text-left font-mono text-micro uppercase tracking-[0.18em] text-muted">
                <th className="border-b border-line px-4 py-1.5 font-normal">When</th>
                <th className="border-b border-line px-4 py-1.5 text-right font-normal">Drift (bps)</th>
                <th className="border-b border-line px-4 py-1.5 font-normal">Class</th>
                <th className="border-b border-line px-4 py-1.5 font-normal">Fee mode</th>
                <th className="border-b border-line px-4 py-1.5 text-right font-normal">Tx</th>
              </tr>
            </thead>
            <tbody className="tabular font-mono text-ink/90">
              {rows.map((row) => (
                <tr key={row.id} className="border-b border-line/50 hover:bg-white/[0.02]">
                  <td className="border-b border-line/60 px-4 py-1.5 text-muted">{relative(row.timestamp)}</td>
                  <td
                    className={`border-b border-line/60 px-4 py-1.5 text-right ${
                      row.driftBps > 0n
                        ? "text-neg"
                        : row.driftBps < 0n
                          ? "text-pos"
                          : "text-muted"
                    }`}
                  >
                    {signedBps(row.driftBps)}
                    {row.structuralBreakTriggered ? (
                      <span className="ml-2 inline-flex items-center gap-1 border border-danger/50 bg-danger/10 px-1 text-micro uppercase tracking-wider text-danger">
                        break
                      </span>
                    ) : null}
                  </td>
                  <td className="border-b border-line/60 px-4 py-1.5">
                    <Class classification={row.classification} />
                  </td>
                  <td className="border-b border-line/60 px-4 py-1.5">
                    <span
                      className={`border px-1.5 py-0.5 font-mono text-micro uppercase tracking-wider ${
                        row.asymmetricActive
                          ? "border-line-strong text-ink"
                          : "border-line text-muted"
                      }`}
                    >
                      {row.asymmetricActive ? "asym" : "flat"}
                    </span>
                  </td>
                  <td className="border-b border-line/60 px-4 py-1.5 text-right">
                    <a
                      href={explorerTx(chainId, row.txHash) ?? "#"}
                      target="_blank"
                      rel="noreferrer"
                      className="text-muted hover:text-ink"
                      title={row.txHash}
                    >
                      {row.txHash.slice(0, 6)}…↗
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function Class({classification}: {classification: "corrective" | "adversarial" | "neutral" | undefined}) {
  if (classification === "corrective")
    return (
      <span className="inline-flex items-center gap-1.5 text-pos">
        <Dot color="bg-pos" /> Corrective
      </span>
    );
  if (classification === "adversarial")
    return (
      <span className="inline-flex items-center gap-1.5 text-neg">
        <Dot color="bg-neg" /> Adversarial
      </span>
    );
  if (classification === "neutral")
    return (
      <span className="inline-flex items-center gap-1.5 text-muted">
        <Dot color="bg-subtle" /> Neutral
      </span>
    );
  return <span className="text-subtle">-</span>;
}

function Dot({color}: {color: string}) {
  return <span className={`inline-block h-1.5 w-1.5 rounded-full ${color}`} />;
}

function EmptyRow({msg, tone = "muted"}: {msg: string; tone?: "muted" | "warn"}) {
  return (
    <div
      className={`px-5 py-6 text-center font-mono text-2xs ${
        tone === "warn" ? "text-warn" : "text-muted"
      }`}
    >
      {msg}
    </div>
  );
}

function signedBps(bps: bigint): string {
  const sign = bps > 0n ? "+" : "";
  return `${sign}${bps.toString()}`;
}

function relative(ts: bigint | undefined): string {
  if (ts === undefined) return "-";
  const now = Math.floor(Date.now() / 1000);
  const delta = now - Number(ts);
  if (delta < 60) return `${delta}s`;
  if (delta < 3600) return `${Math.floor(delta / 60)}m`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h`;
  return `${Math.floor(delta / 86400)}d`;
}
