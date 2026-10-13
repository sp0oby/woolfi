"use client";

import {useAccount, useSwitchChain} from "wagmi";

import {isWrongNetwork} from "@/lib/txGuards";
import {robinhood} from "@/lib/wagmi";

/**
 * Wrong-network detection from the wallet's real chain. `useChainId()` can't be used for this:
 * wagmi only configures Robinhood Chain and keeps reporting it while the wallet sits on an
 * unconfigured chain. `useAccount().chainId` is the connector's actual chain.
 */
export function useWrongNetwork() {
  const {isConnected, chainId} = useAccount();
  const {switchChain, isPending} = useSwitchChain();
  return {
    wrongNetwork: isWrongNetwork(isConnected, chainId, robinhood.id),
    accountChainId: chainId,
    switching: isPending,
    switchToRobinhood: () => switchChain({chainId: robinhood.id}),
  };
}
