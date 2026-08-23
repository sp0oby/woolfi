"use client";

import {useEffect, useState} from "react";
import {useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useAllowance, useUserReads} from "@/hooks/usePool";
import {erc20Abi, pmAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, StatRow, TxStatus} from "../atoms";
import {btnCls, parseAmount} from "../panelHelpers";

type UserReads = ReturnType<typeof useUserReads>;

export function DepositMode({
  deployment,
  address,
  a0,
  setA0,
  a1,
  setA1,
  user,
  drift,
  totalShares,
}: {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
  a0: string;
  setA0: (value: string) => void;
  a1: string;
  setA1: (value: string) => void;
  user: UserReads;
  drift: bigint | undefined;
  totalShares: bigint | undefined;
}) {
  const key = poolKeyFor(deployment);
  const a0Wei = parseAmount(a0, 18);
  const a1Wei = parseAmount(a1, 18);
  const allow0 = useAllowance(deployment.token0, address, deployment.positionManager);
  const allow1 = useAllowance(deployment.token1, address, deployment.positionManager);
  const {writeContract: approve0, data: tx0, isPending: pending0} = useWriteContract();
  const {writeContract: approve1, data: tx1, isPending: pending1} = useWriteContract();
  const {writeContract: mint, data: txMint, isPending: pendingMint} = useWriteContract();
  const wait0 = useWaitForTransactionReceipt({hash: tx0});
  const wait1 = useWaitForTransactionReceipt({hash: tx1});
  const waitMint = useWaitForTransactionReceipt({hash: txMint});

  // Keep a local allowance shadow while RPC/react-query reads catch up to confirmed approvals.
  const [optAllow0, setOptAllow0] = useState<bigint>(0n);
  const [optAllow1, setOptAllow1] = useState<bigint>(0n);
  useEffect(() => {
    if (wait0.isSuccess && a0Wei !== undefined && a0Wei > optAllow0) {
      setOptAllow0(a0Wei);
      allow0.refetch();
    }
  }, [wait0.isSuccess, a0Wei, allow0, optAllow0]);
  useEffect(() => {
    if (wait1.isSuccess && a1Wei !== undefined && a1Wei > optAllow1) {
      setOptAllow1(a1Wei);
      allow1.refetch();
    }
  }, [wait1.isSuccess, a1Wei, allow1, optAllow1]);

  const eff0 = max(allow0.data ?? 0n, optAllow0);
  const eff1 = max(allow1.data ?? 0n, optAllow1);
  const needs0 = a0Wei !== undefined && eff0 < a0Wei;
  const needs1 = a1Wei !== undefined && eff1 < a1Wei;
  const busy =
    pending0 || pending1 || pendingMint || wait0.isLoading || wait1.isLoading || waitMint.isLoading;

  function onClick() {
    if (!a0Wei || !a1Wei || !address) return;
    if (needs0) {
      approve0({
        address: deployment.token0,
        abi: erc20Abi,
        functionName: "approve",
        args: [deployment.positionManager, a0Wei],
      });
      return;
    }
    if (needs1) {
      approve1({
        address: deployment.token1,
        abi: erc20Abi,
        functionName: "approve",
        args: [deployment.positionManager, a1Wei],
      });
      return;
    }
    mint({
      address: deployment.positionManager,
      abi: pmAbi,
      functionName: "mint",
      args: [key, a0Wei, a1Wei, address],
    });
  }

  const ready = !!a0Wei && !!a1Wei && !!address && !busy;
  return (
    <>
      <Field label="Deposit" token={deployment.token0Symbol} value={a0} onChange={setA0} editable hint={`balance ${fmtAmount(user.bal0)}`} />
      <Field label="Deposit" token={deployment.token1Symbol} value={a1} onChange={setA1} editable hint={`balance ${fmtAmount(user.bal1)}`} />
      <StatRow
        stats={[
          {label: "Your LP shares", value: fmtAmount(user.lpShares)},
          {label: "Pool drift (bps)", value: drift !== undefined ? signedBps(drift) : "-"},
          {label: "Total LP shares", value: fmtAmount(totalShares)},
        ]}
      />
      <button type="button" disabled={!ready} onClick={onClick} className={btnCls(!ready)}>
        {!address
          ? "Connect wallet"
          : !a0Wei || !a1Wei
            ? "Enter amounts"
            : pending0 || wait0.isLoading
              ? `Approving ${deployment.token0Symbol}…`
              : pending1 || wait1.isLoading
                ? `Approving ${deployment.token1Symbol}…`
                : pendingMint || waitMint.isLoading
                  ? "Providing liquidity…"
                  : needs0
                    ? `Approve ${deployment.token0Symbol}`
                    : needs1
                      ? `Approve ${deployment.token1Symbol}`
                      : "Provide liquidity"}
      </button>
      <TxStatus hash={txMint ?? tx1 ?? tx0} />
    </>
  );
}

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
      <StatRow
        stats={[
          {label: "Your LP shares", value: fmtAmount(user.lpShares)},
          {label: `Pending ${deployment.token0Symbol}`, value: fmtAmount(user.lpShares ? undefined : 0n)},
          {label: `Pending ${deployment.token1Symbol}`, value: fmtAmount(user.lpShares ? undefined : 0n)},
        ]}
      />
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

function max(a: bigint, b: bigint): bigint {
  return a > b ? a : b;
}

function signedBps(bps: bigint): string {
  const sign = bps > 0n ? "+" : "";
  return `${sign}${bps.toString()}`;
}
