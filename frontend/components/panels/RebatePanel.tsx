"use client";

import {useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useSelectedPool} from "@/hooks/useSelectedPool";
import {rebateDistributorAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {PanelFootnote, TxStatus} from "./atoms";

export function RebatePanel() {
  const {deployment, pool} = useSelectedPool();
  if (!deployment?.rebateDistributor) {
    return (
      <PanelFootnote>
        Urufu Gemu holder rebates for {pool.base.symbol} / {pool.quote.symbol} activate after the
        verified router and funded rebate distributor are live.
      </PanelFootnote>
    );
  }

  return (
    <Live
      deployment={deployment as WoolFiDeployment & {rebateDistributor: `0x${string}`}}
    />
  );
}

function Live({
  deployment,
}: {
  deployment: WoolFiDeployment & {rebateDistributor: `0x${string}`};
}) {
  const {address} = useAccount();
  const {writeContract, data: tx, isPending} = useWriteContract();
  const wait = useWaitForTransactionReceipt({hash: tx});
  const rebate0 = useReadContract({
    address: deployment.rebateDistributor,
    abi: rebateDistributorAbi,
    functionName: "claimable",
    args: [address ?? deployment.rebateDistributor, deployment.token0],
    query: {enabled: !!address},
  });
  const rebate1 = useReadContract({
    address: deployment.rebateDistributor,
    abi: rebateDistributorAbi,
    functionName: "claimable",
    args: [address ?? deployment.rebateDistributor, deployment.token1],
    query: {enabled: !!address},
  });

  const amount0 = rebate0.data ?? 0n;
  const amount1 = rebate1.data ?? 0n;

  function claim(token: `0x${string}`) {
    if (!address) return;
    writeContract({
      address: deployment.rebateDistributor,
      abi: rebateDistributorAbi,
      functionName: "claim",
      args: [token, address],
    });
  }

  return (
    <div className="space-y-5">
      <RebateRow
        symbol={deployment.token0Symbol}
        amount={amount0}
        decimals={deployment.token0Decimals}
        disabled={!address || amount0 === 0n || isPending || wait.isLoading}
        onClaim={() => claim(deployment.token0)}
      />
      <RebateRow
        symbol={deployment.token1Symbol}
        amount={amount1}
        decimals={deployment.token1Decimals}
        disabled={!address || amount1 === 0n || isPending || wait.isLoading}
        onClaim={() => claim(deployment.token1)}
      />
      <TxStatus hash={tx} />
      <PanelFootnote>
        Hold at least one Urufu Gemu NFT when a swap settles to earn 15% of its base-fee portion
        back in the input token. Surcharges are excluded and weekly caps apply.
      </PanelFootnote>
    </div>
  );
}

function RebateRow({
  symbol,
  amount,
  decimals,
  disabled,
  onClaim,
}: {
  symbol: string;
  amount: bigint;
  decimals: number;
  disabled: boolean;
  onClaim: () => void;
}) {
  return (
    <div className="border border-line px-5 py-4 flex items-center justify-between gap-4">
      <div>
        <div className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">{symbol}</div>
        <div className="mt-1 font-mono text-lg text-white">{fmtAmount(amount, decimals)}</div>
      </div>
      <button
        type="button"
        disabled={disabled}
        onClick={onClaim}
        className={`border border-line px-4 py-2 font-mono text-[10px] uppercase tracking-[0.18em] ${
          disabled ? "text-muted cursor-not-allowed" : "text-white hover:bg-white/5"
        }`}
      >
        Claim
      </button>
    </div>
  );
}
