"use client";

import {createContext, useCallback, useContext, useEffect, useMemo, useState} from "react";
import {useWrongNetwork} from "@/hooks/useWrongNetwork";
import {defaultPool, findPoolBySlug, poolRegistry} from "@/lib/pools/registry";
import type {CuratedPool} from "@/lib/pools/types";
import {deploymentForPool, preferredDeploymentChainId, type WoolFiDeployment} from "@/lib/woolfi";

type SelectedPoolValue = {
  pool: CuratedPool;
  /** Always the Robinhood Chain deployment: reads stay pinned there whatever the wallet is on. */
  deployment: WoolFiDeployment | null;
  /** Wallet connected on another chain (from the account's real chain). Actions must stay off. */
  wrongNetwork: boolean;
  pools: readonly CuratedPool[];
  selectPool: (slug: string) => void;
};

const SelectedPoolContext = createContext<SelectedPoolValue | null>(null);

export function SelectedPoolProvider({children}: {children: React.ReactNode}) {
  const {wrongNetwork} = useWrongNetwork();
  const [slug, setSlug] = useState(defaultPool.slug);

  const readUrl = useCallback(() => {
    const requested = new URLSearchParams(window.location.search).get("pool");
    setSlug(findPoolBySlug(requested)?.slug ?? defaultPool.slug);
  }, []);

  useEffect(() => {
    readUrl();
    window.addEventListener("popstate", readUrl);
    return () => window.removeEventListener("popstate", readUrl);
  }, [readUrl]);

  const selectPool = useCallback((nextSlug: string) => {
    const next = findPoolBySlug(nextSlug);
    if (!next) return;
    const url = new URL(window.location.href);
    url.searchParams.set("pool", next.slug);
    window.history.pushState({}, "", url);
    setSlug(next.slug);
  }, []);

  const pool = findPoolBySlug(slug) ?? defaultPool;
  const value = useMemo(
    () => ({
      pool,
      deployment: deploymentForPool(preferredDeploymentChainId, pool),
      wrongNetwork,
      pools: poolRegistry,
      selectPool,
    }),
    [wrongNetwork, pool, selectPool],
  );

  return <SelectedPoolContext.Provider value={value}>{children}</SelectedPoolContext.Provider>;
}

export function useSelectedPool(): SelectedPoolValue {
  const value = useContext(SelectedPoolContext);
  if (!value) throw new Error("useSelectedPool must be used within SelectedPoolProvider");
  return value;
}
