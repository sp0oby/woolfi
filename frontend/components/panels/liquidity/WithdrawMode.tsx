"use client";

import {useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useUserReads} from "@/hooks/usePool";
import {pmAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, StatRow, TxStatus} from "../atoms";
import {btnCls, parseAmount} from "../panelHelpers";

type UserReads = ReturnType<typeof useUserReads>;

export function WithdrawMode({
  deployment,
  address,
  sharesIn,
  setShares,
  user,
}: {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
  sharesIn: string;
  setShares: (value: string) => void;
  user: UserReads;
}) {
  const key = poolKeyFor(deployment);
  const sharesWei = parseAmount(sharesIn, 18);
  const {writeContract: burn, data: tx, isPending} = useWriteContract();
  const wait = useWaitForTransactionReceipt({hash: tx});
  const {writeContract: collect, data: ctx, isPending: collectPending} = useWriteContract();
  const collectWait = useWaitForTransactionReceipt({hash: ctx});
  const validShares = sharesWei !== undefined && sharesWei > 0n;
  const tooMany = validShares && user.lpShares !== undefined && sharesWei > user.lpShares;
  const ready = !!address && validShares && !tooMany && !isPending && !wait.isLoading;

  return (
    <>
      <Field label="Burn" token="LP shares" value={sharesIn} onChange={setShares} editable hint={`your shares ${fmtAmount(user.lpShares)}`} />
      <StatRow stats={[
        {label: "Your LP shares", value: fmtAmount(user.lpShares)},
        {label: `Pending ${deployment.token0Symbol}`, value: fmtAmount(user.pendingLpFees?.[0], deployment.token0Decimals)},
        {label: `Pending ${deployment.token1Symbol}`, value: fmtAmount(user.pendingLpFees?.[1], deployment.token1Decimals)},
      ]} />
      <button
        type="button"
        disabled={!ready}
        onClick={() => {
          if (!sharesWei || !address) return;
          burn({address: deployment.positionManager, abi: pmAbi, functionName: "burn", args: [key, sharesWei, address]});
        }}
        className={btnCls(!ready)}
      >
        {!address
          ? "Connect wallet"
          : !validShares
            ? "Enter shares"
            : tooMany
              ? "Exceeds your shares"
              : isPending || wait.isLoading
                ? "Withdrawing…"
                : "Withdraw"}
      </button>
      <button
        type="button"
        disabled={!address || collectPending || collectWait.isLoading}
        onClick={() => {
          if (!address) return;
          collect({address: deployment.positionManager, abi: pmAbi, functionName: "collectFees", args: [key, address]});
        }}
        className={btnCls(!address || collectPending || collectWait.isLoading)}
      >
        {!address
          ? "Connect wallet"
          : collectPending || collectWait.isLoading
            ? "Collecting…"
            : "Collect fees only"}
      </button>
      <TxStatus hash={ctx ?? tx} />
    </>
  );
}
