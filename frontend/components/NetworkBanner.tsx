"use client";

import {useWrongNetwork} from "@/hooks/useWrongNetwork";
import {chainNameById, robinhood} from "@/lib/wagmi";

/**
 * Honest "wrong network" prompt. Renders nothing in the happy path. If a wallet is connected
 * to a chain WoolFi doesn't support, this asks the user to switch to an active deployment.
 * Detection uses the wallet's real chain (see useWrongNetwork), not wagmi's configured chain.
 */
export function NetworkBanner() {
  const {wrongNetwork, accountChainId, switching, switchToRobinhood} = useWrongNetwork();

  if (!wrongNetwork) return null;

  const current =
    accountChainId !== undefined ? (chainNameById[accountChainId] ?? `chain ${accountChainId}`) : "this network";

  return (
    <div className="mt-8 border border-line px-5 py-4 flex items-baseline justify-between gap-4">
      <div>
        <div className="font-mono text-[11px] uppercase tracking-[0.22em] text-amber-200/90">
          Wrong network
        </div>
        <div className="mt-1 font-mono text-[13px] text-muted">
          No WoolFi deployment is configured on {current}.
        </div>
      </div>
      <button
        type="button"
        disabled={switching}
        onClick={switchToRobinhood}
        className="font-mono text-[11px] uppercase tracking-[0.22em] text-white border border-line px-4 py-2 hover:bg-white/5 disabled:text-muted disabled:cursor-not-allowed"
      >
        {switching ? "Switching…" : `Switch to ${chainNameById[robinhood.id]}`}
      </button>
    </div>
  );
}
