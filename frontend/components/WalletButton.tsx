"use client";

import {ConnectButton} from "@rainbow-me/rainbowkit";

/**
 * Minimal RainbowKit connect button, styled to match the editorial mono nav.
 * - Disconnected: small uppercase "Connect" link.
 * - Connected:   small uppercase address (ENS if available) with a status dot.
 * - Wrong net:   small uppercase "Wrong network" warning that opens the chain modal.
 */
export function WalletButton() {
  return (
    <ConnectButton.Custom>
      {({account, chain, openAccountModal, openChainModal, openConnectModal, mounted}) => {
        // hydration-safe: render nothing until rainbowkit has mounted
        if (!mounted) {
          return (
            <span className="font-mono text-2xs uppercase tracking-[0.14em] sm:text-xs sm:tracking-[0.18em] text-muted opacity-0">
              Connect
            </span>
          );
        }
        const connected = !!account && !!chain;
        if (!connected) {
          return (
            <button
              type="button"
              onClick={openConnectModal}
              className="font-mono text-2xs uppercase tracking-[0.14em] sm:text-xs sm:tracking-[0.18em] text-muted hover:text-ink transition-colors"
            >
              Connect
            </button>
          );
        }
        if (chain.unsupported) {
          return (
            <button
              type="button"
              onClick={openChainModal}
              className="font-mono text-2xs uppercase tracking-[0.14em] sm:text-xs sm:tracking-[0.18em] text-amber-300/90 hover:text-amber-200 transition-colors"
            >
              Wrong network
            </button>
          );
        }
        return (
          <button
            type="button"
            onClick={openAccountModal}
            className="font-mono text-2xs uppercase tracking-[0.14em] sm:text-xs sm:tracking-[0.18em] text-ink hover:text-white transition-colors inline-flex items-center gap-2"
          >
            <span aria-hidden className="inline-block w-1.5 h-1.5 rounded-full bg-ink/70" />
            {account.displayName}
          </button>
        );
      }}
    </ConnectButton.Custom>
  );
}
