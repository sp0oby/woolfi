"use client";

import {createContext, useCallback, useContext, useEffect, useMemo, useState} from "react";
import {useChainId} from "wagmi";

import {defaultPool, findPoolBySlug, poolRegistry} from "@/lib/pools/registry";
import type {CuratedPool} from "@/lib/pools/types";
import {deploymentForPool, type WoolFiDeployment} from "@/lib/woolfi";

type SelectedPoolValue = {
  pool: CuratedPool;
  deployment: WoolFiDeployment | null;
  pools: readonly CuratedPool[];
  selectPool: (slug: string) => void;
};

const SelectedPoolContext = createContext<SelectedPoolValue | null>(null);

export function SelectedPoolProvider({children}: {children: React.ReactNode}) {
  const chainId = useChainId();
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
      deployment: deploymentForPool(chainId, pool),
      pools: poolRegistry,
      selectPool,
    }),
    [chainId, pool, selectPool],
  );

  return <SelectedPoolContext.Provider value={value}>{children}</SelectedPoolContext.Provider>;
}

export function useSelectedPool(): SelectedPoolValue {
  const value = useContext(SelectedPoolContext);
  if (!value) throw new Error("useSelectedPool must be used within SelectedPoolProvider");
  return value;
}
