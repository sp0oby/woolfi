"use client";

import {useAccount, useChainId, useSwitchChain} from "wagmi";

import {preferredDeploymentChainId} from "@/lib/woolfi";
import {chainNameById, type ConfiguredChainId} from "@/lib/wagmi";

/**
 * Honest "wrong network" prompt. Renders nothing in the happy path. If a wallet is connected
 * to a chain WoolFi doesn't support, this asks the user to switch to an active deployment.
 */
export function NetworkBanner() {
  const {isConnected} = useAccount();
  const chainId = useChainId();
  const {switchChain, isPending} = useSwitchChain();

  if (!isConnected) return null;
  if (chainId === preferredDeploymentChainId) return null;

  const current = chainNameById[chainId] ?? `chain ${chainId}`;

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
        disabled={isPending}
        onClick={() => switchChain({chainId: preferredDeploymentChainId as ConfiguredChainId})}
        className="font-mono text-[11px] uppercase tracking-[0.22em] text-white border border-line px-4 py-2 hover:bg-white/5 disabled:text-muted disabled:cursor-not-allowed"
      >
        {isPending ? "Switching…" : `Switch to ${chainNameById[preferredDeploymentChainId]}`}
      </button>
    </div>
  );
}
