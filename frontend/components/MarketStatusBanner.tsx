"use client";

import {useChainId} from "wagmi";

import {useHookSwaps} from "@/hooks/useHookSwaps";
import {usePoolReads} from "@/hooks/usePool";
import {useSelectedPool} from "@/hooks/useSelectedPool";
import {explorerAddress} from "@/lib/wagmi";

/**
 * Surfaces closed, stabilizing, skewed, and structural-break modes for the selected pool.
 * Live state comes from contract reads; indexer lag is a separate warning.
 */
export function MarketStatusBanner() {
  const {pool} = useSelectedPool();
  const {marketOpen, deployment, safety, drift} = usePoolReads();
  const {stale: indexerStale} = useHookSwaps();
  const chainId = useChainId();

  if (!deployment) return null;

  const oracleLink = explorerAddress(chainId, deployment.marketHours);
  const broken = safety?.structurallyBroken === true;
  const stabilizing = safety?.stabilizing === true;
  const skewed = safety?.oracleSkewed === true;
  const corrective =
    drift === undefined || drift === 0n
      ? "either direction"
      : drift > 0n
        ? `sell ${deployment.token0Symbol}`
        : `buy ${deployment.token0Symbol}`;

  return (
    <div className="mt-6 space-y-3">
      {broken ? (
        <Banner tone="danger" title={`Structural break · corrective only · ${corrective}`}>
          New liquidity is blocked. Swaps are admitted only when they reduce drift against the
          cached break fair. Withdrawals stay open.
        </Banner>
      ) : stabilizing ? (
        <Banner tone="warn" title="Opening stabilization · flat fees · no new liquidity">
          The referenced market just opened. Asymmetric fees stay off until the configured
          stabilization interval elapses.
        </Banner>
      ) : skewed ? (
        <Banner tone="warn" title="Oracle timestamp skew · flat-fee degraded mode">
          The two price legs are too far apart in time. Swaps still settle at the base fee;
          deposits are blocked until the feeds resynchronize.
        </Banner>
      ) : pool.tradingHours === "always-open" ? (
        <div className="border border-line/70 px-4 py-2.5 font-mono text-[11px] uppercase tracking-[0.22em] text-emerald-300/85">
          Always open · asymmetric fee active
        </div>
      ) : marketOpen === undefined ? null : marketOpen ? (
        <div className="border border-line/70 px-4 py-2.5">
          <div className="flex items-center gap-3 font-mono text-[11px] uppercase tracking-[0.22em] text-emerald-300/85">
            <span className="inline-block size-1.5 rounded-full bg-emerald-300/85" />
            Underlying market open · asymmetric fee active
          </div>
          <HoursNote href={oracleLink} />
        </div>
      ) : (
        <div className="border border-amber-200/30 bg-amber-200/[0.04] px-4 py-3">
          <div className="flex items-center gap-3 font-mono text-[11px] uppercase tracking-[0.22em] text-amber-100/95">
            <span className="inline-block size-1.5 rounded-full bg-amber-200/90" />
            Underlying market closed · flat fees · no convergence promise
          </div>
          <p className="mt-2.5 text-[12px] leading-relaxed text-amber-50/80">
            {pool.base.symbol} tracks a referenced security. While its underlying market is closed,
            swaps still settle, but the pool does not promise to mean-revert. LPs bear gap risk
            over the close.
          </p>
          <HoursNote href={oracleLink} muted />
        </div>
      )}
      {indexerStale ? (
        <Banner tone="warn" title="Indexer behind">
          Recent history may be stale. Live prices and pool status still come from the contracts.
        </Banner>
      ) : null}
    </div>
  );
}

function Banner({
  tone,
  title,
  children,
}: {
  tone: "warn" | "danger";
  title: string;
  children: string;
}) {
  const cls =
    tone === "danger"
      ? "border-rose-300/30 bg-rose-300/[0.05] text-rose-100/95"
      : "border-amber-200/30 bg-amber-200/[0.04] text-amber-100/95";
  return (
    <div className={`border px-4 py-3 ${cls}`}>
      <div className="font-mono text-[11px] uppercase tracking-[0.22em]">{title}</div>
      <p className="mt-2 text-[12px] leading-relaxed normal-case tracking-normal">{children}</p>
    </div>
  );
}

function HoursNote({href, muted}: {href: string | null | undefined; muted?: boolean}) {
  return (
    <p className={`mt-2 font-mono text-[10px] uppercase tracking-[0.18em] ${muted ? "text-amber-50/60" : "text-muted"}`}>
      Computed on-chain ·{" "}
      {href ? (
        <a href={href} target="_blank" rel="noreferrer" className="hover:text-ink transition-colors">
          Market hours ↗
        </a>
      ) : (
        "Market hours"
      )}
    </p>
  );
}
