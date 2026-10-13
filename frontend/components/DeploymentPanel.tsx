"use client";

import {useChainId} from "wagmi";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {getDeploymentConfig} from "@/lib/woolfi";
import {explorerAddress} from "@/lib/wagmi";

/**
 * Surfaces the active chain's contracts from the receipt-backed deployment manifest, in two
 * groups: WoolFi's own contracts ("not deployed" until launch), and the existing third-party
 * contracts WoolFi builds on. Keeping them apart stops Uniswap's PoolManager or the URU token
 * from reading as if WoolFi were already partly deployed.
 */
export function DeploymentPanel() {
  const chainId = useChainId();
  const {pool, deployment} = useSelectedPool();
  const config = getDeploymentConfig(chainId);

  return (
    <section className="mt-24">
      <h2 className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">Deployment</h2>
      {config ? (
        <>
          <Group title={`WoolFi contracts · chain ${config.chainId}`}>
            <AddrRow chainId={chainId} label="Hook" addr={config.hook} />
            <AddrRow chainId={chainId} label="Position manager" addr={config.positionManager} />
            <AddrRow chainId={chainId} label="Governor" addr={config.governor} />
            <AddrRow chainId={chainId} label="Timelock" addr={config.timelock} />
            <AddrRow chainId={chainId} label="Swap router" addr={config.swapRouter} />
            <AddrRow chainId={chainId} label="Liquidity zapper" addr={config.liquidityZapper} />
            <AddrRow chainId={chainId} label="Pool aligner" addr={config.poolAligner} />
            <AddrRow chainId={chainId} label="Rebate distributor" addr={config.rebateDistributor} />
            <AddrRow chainId={chainId} label={`${pool.base.symbol}/${pool.quote.symbol} vault`} addr={deployment?.vault} />
          </Group>
          <Group title="Existing contracts WoolFi uses (not deployed by WoolFi)">
            <AddrRow chainId={chainId} label="Uniswap v4 PoolManager" addr={config.poolManager} />
            <AddrRow chainId={chainId} label="Uniswap v3 swap router (zap route)" addr={config.externalSwapExecutor} />
            <AddrRow chainId={chainId} label={`${config.stakingSymbol} token`} addr={config.stakingToken} />
            <AddrRow chainId={chainId} label="Urufu Gemu NFT" addr={config.urufuNft} />
            <AddrRow chainId={chainId} label={pool.base.symbol} addr={pool.base.address} />
            <AddrRow chainId={chainId} label={pool.quote.symbol} addr={pool.quote.address} />
          </Group>
        </>
      ) : (
        <p className="mt-4 font-mono text-[13px] text-muted">
          No deployment manifest found for this chain.
        </p>
      )}
    </section>
  );
}

function Group({title, children}: {title: string; children: React.ReactNode}) {
  return (
    <div className="mt-5">
      <h3 className="font-mono text-[10px] uppercase tracking-[0.2em] text-subtle">{title}</h3>
      <dl className="mt-3 grid grid-cols-[minmax(8rem,14rem)_1fr] gap-x-4 gap-y-3 font-mono text-[12px] text-ink/85">
        {children}
      </dl>
    </div>
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
