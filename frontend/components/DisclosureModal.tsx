"use client";

import {useEffect, useState} from "react";
import {useSelectedPool} from "@/hooks/useSelectedPool";

const STORAGE_KEY = "woolfi.disclosure.ack.v3";

/**
 * First-visit dismissable modal explaining the tokenized-equity dependency.
 *
 * Acknowledgement is persisted to localStorage so the modal does not nag returning users.
 */
export function DisclosureModal() {
  const {pool} = useSelectedPool();
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const ack = window.localStorage.getItem(STORAGE_KEY);
      if (!ack) setOpen(true);
    } catch {
      // Privacy-mode browsers throw on localStorage access; default to showing the modal.
      setOpen(true);
    }
  }, []);

  function acknowledge() {
    try {
      window.localStorage.setItem(STORAGE_KEY, new Date().toISOString());
    } catch {
      // Best-effort; ignore quota / privacy errors.
    }
    setOpen(false);
  }

  if (!open || pool.tradingHours === "always-open") return null;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="woolfi-disclosure-title"
      className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/70 backdrop-blur-sm px-4 py-6"
    >
      <div className="w-full max-w-lg border border-line bg-bg text-ink shadow-2xl">
        <div className="px-6 pt-6 pb-2">
          <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">Disclosure</p>
          <h2 id="woolfi-disclosure-title" className="mt-2 text-[20px] font-medium tracking-tight">
            This selected pool includes Robinhood Stock Token exposure.
          </h2>
        </div>
        <div className="px-6 pb-5 space-y-4 text-[14px] leading-relaxed text-ink/85">
          <p>
            The selected pair is{" "}
            <span className="font-mono text-white">
              {pool.base.symbol} / {pool.quote.symbol}
            </span>
            . One or both assets may be Robinhood Stock Tokens issued by Robinhood Assets (Jersey)
            Limited (RHJ). They provide economic exposure to referenced securities, not ownership,
            voting rights, or other shareholder rights in those securities.
          </p>
          <p>
            WoolFi is a smart-contract protocol and does not determine your eligibility. The pool
            inherits the issuer's geographic, transfer, and market-access restrictions. You are
            responsible for confirming that you may hold and trade this token.
          </p>
          <p>
            While the applicable U.S. equity market is closed, the hook drops its asymmetric
            mechanic and uses flat fees. LPs bear overnight and weekend gap risk. WoolFi is
            pre-launch, unaudited, and provides no investment advice.
          </p>
        </div>
        <div className="border-t border-line px-6 py-4 flex flex-col sm:flex-row gap-3 sm:gap-4 sm:items-center sm:justify-end">
          <a
            href="https://docs.robinhood.com/chain/stock-tokens/"
            target="_blank"
            rel="noreferrer"
            className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted hover:text-white transition-colors"
          >
            Robinhood token terms ↗
          </a>
          <button
            type="button"
            onClick={acknowledge}
            className="inline-flex items-center justify-center border border-line px-6 py-2.5 font-mono text-[11px] uppercase tracking-[0.22em] text-white hover:bg-white/5 transition-colors"
          >
            I understand
          </button>
        </div>
      </div>
    </div>
  );
}
