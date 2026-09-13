"use client";

import {useChainId} from "wagmi";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {getDeploymentConfig} from "@/lib/woolfi";
import {explorerAddress} from "@/lib/wagmi";

/**
 * Surfaces the active chain's deployed WoolFi contracts (or "no deployment found" honestly).
 * Reads from the receipt-backed chain deployment manifest.
 */
export function DeploymentPanel() {
  const chainId = useChainId();
  const {pool, deployment} = useSelectedPool();
  const config = getDeploymentConfig(chainId);

  return (
    <section className="mt-24">
      <h2 className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">Deployment</h2>
      {config ? (
        <dl className="mt-4 font-mono text-[12px] text-ink/85 grid grid-cols-[10rem_1fr] gap-y-3">
          <dt className="text-muted">Chain</dt>
          <dd className="text-white">{config.chainId}</dd>
          <AddrRow chainId={chainId} label="Pool manager" addr={config.poolManager} />
          <AddrRow chainId={chainId} label="Hook" addr={config.hook} />
          <AddrRow chainId={chainId} label="Position manager" addr={config.positionManager} />
          <AddrRow chainId={chainId} label="Swap router" addr={config.swapRouter} />
          <AddrRow chainId={chainId} label="Liquidity zapper" addr={config.liquidityZapper} />
          <AddrRow chainId={chainId} label="External swap executor" addr={config.externalSwapExecutor} />
          <AddrRow chainId={chainId} label="Rebate distributor" addr={config.rebateDistributor} />
          <AddrRow chainId={chainId} label="Urufu Gemu NFT" addr={config.urufuNft} />
          <AddrRow chainId={chainId} label="Governor" addr={config.governor} />
          <AddrRow chainId={chainId} label={config.stakingSymbol} addr={config.stakingToken} />
          <AddrRow chainId={chainId} label={pool.base.symbol} addr={pool.base.address} />
          <AddrRow chainId={chainId} label={pool.quote.symbol} addr={pool.quote.address} />
          <AddrRow chainId={chainId} label="Vault" addr={deployment?.vault} />
        </dl>
      ) : (
        <p className="mt-4 font-mono text-[13px] text-muted">
          No deployment manifest found for this chain.
        </p>
      )}
    </section>
  );
}

function AddrRow({chainId, label, addr}: {chainId: number; label: string; addr: `0x${string}` | undefined}) {
  if (!addr || addr === "0x0000000000000000000000000000000000000000") {
    return (
      <>
        <dt className="text-muted">{label}</dt>
        <dd className="text-muted">- not deployed -</dd>
      </>
    );
  }
  const url = explorerAddress(chainId, addr);
  return (
    <>
      <dt className="text-muted">{label}</dt>
      <dd className="break-all">
        {url ? (
          <a href={url} target="_blank" rel="noreferrer" className="text-white hover:underline">
            {addr} ↗
          </a>
        ) : (
          <span className="text-white">{addr}</span>
        )}
      </dd>
    </>
  );
}
