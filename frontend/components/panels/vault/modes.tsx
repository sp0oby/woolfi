"use client";

import {useEffect, useState} from "react";
import {useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useAllowance, useUserReads} from "@/hooks/usePool";
import {erc20Abi, vaultAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, StatRow, TxStatus} from "../atoms";
import {btnCls, parseAmount} from "../panelHelpers";

type UserReads = ReturnType<typeof useUserReads>;
type ModeProps = {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
  user: UserReads;
};

export function StakeMode({
  deployment,
  address,
  amount,
  setAmount,
  user,
  vaultStaked,
}: ModeProps & {
  amount: string;
  setAmount: (value: string) => void;
  vaultStaked: bigint | undefined;
}) {
  const amountWei = parseAmount(amount, 18);
  const allowance = useAllowance(deployment.stakingToken, address, deployment.vault);
  const {writeContract: approve, data: approveTx, isPending: approving} = useWriteContract();
  const {writeContract: stake, data: stakeTx, isPending: staking} = useWriteContract();
  const approveWait = useWaitForTransactionReceipt({hash: approveTx});
  const stakeWait = useWaitForTransactionReceipt({hash: stakeTx});

  // Keep a local allowance shadow while RPC/react-query reads catch up to confirmed approvals.
  const [optAllow, setOptAllow] = useState<bigint>(0n);
  useEffect(() => {
    if (approveWait.isSuccess && amountWei !== undefined && amountWei > optAllow) {
      setOptAllow(amountWei);
      allowance.refetch();
    }
  }, [approveWait.isSuccess, amountWei, allowance, optAllow]);
  const effAllow = (allowance.data ?? 0n) > optAllow ? (allowance.data ?? 0n) : optAllow;
  const needsApproval = amountWei !== undefined && effAllow < amountWei;
  const busy = approving || staking || approveWait.isLoading || stakeWait.isLoading;
  const disabled = !address || amountWei === undefined || amountWei === 0n || busy;

  return (
    <>
      <Field label="Stake" token={deployment.stakingSymbol} value={amount} onChange={setAmount} editable hint={`balance ${fmtAmount(user.stakingTokenBal)}`} />
      <StatRow
        stats={[
          {label: "Your stake", value: fmtAmount(user.vaultStake)},
          {label: "Vault TVL", value: fmtAmount(vaultStaked)},
          {label: "Pending rewards", value: fmtRewardPair(user.pendingRewards)},
        ]}
      />
      <button
        type="button"
        disabled={disabled}
        onClick={() => {
          if (!amountWei || !address) return;
          if (needsApproval) {
            approve({
              address: deployment.stakingToken,
              abi: erc20Abi,
              functionName: "approve",
              args: [deployment.vault, amountWei],
            });
          } else {
            stake({address: deployment.vault, abi: vaultAbi, functionName: "stake", args: [amountWei]});
          }
        }}
        className={btnCls(disabled)}
      >
        {!address
          ? "Connect wallet"
          : amountWei === undefined || amountWei === 0n
            ? "Enter an amount"
            : approving || approveWait.isLoading
              ? "Approving…"
              : staking || stakeWait.isLoading
                ? "Staking…"
                : needsApproval
                  ? `Approve ${deployment.stakingSymbol}`
                  : "Stake"}
      </button>
      <TxStatus hash={stakeTx ?? approveTx} />
    </>
  );
}

export function UnstakeMode({
  deployment,
  address,
  amount,
  setAmount,
  user,
}: ModeProps & {amount: string; setAmount: (value: string) => void}) {
  const sharesWei = parseAmount(amount, 18);
  const {writeContract: request, data: requestTx, isPending: requesting} = useWriteContract();
  const {writeContract: withdraw, data: withdrawTx, isPending: withdrawing} = useWriteContract();
  const requestWait = useWaitForTransactionReceipt({hash: requestTx});
  const withdrawWait = useWaitForTransactionReceipt({hash: withdrawTx});
  const pending = user.pendingUnstake;
  const hasPending = !!pending && pending[0] > 0n;
  const releaseAt = pending ? Number(pending[1]) : 0;
  const now = Math.floor(Date.now() / 1000);
  const cooldownActive = hasPending && now < releaseAt;

  return (
    <>
      {hasPending ? (
        <div className="border border-line px-5 py-4">
          <div className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">
            Pending unstake
          </div>
          <div className="mt-1 font-mono text-[15px] text-white">{fmtAmount(pending[0])} shares</div>
          <div className="mt-2 font-mono text-[12px] text-muted">
            {cooldownActive ? `Ready in ${Math.max(0, releaseAt - now)}s` : "Cooldown elapsed - ready to withdraw"}
          </div>
        </div>
      ) : (
        <Field label="Request unstake" token="SHARES" value={amount} onChange={setAmount} editable hint={`your stake ${fmtAmount(user.vaultStake)}`} />
      )}
      <StatRow
        stats={[
          {label: "Your stake", value: fmtAmount(user.vaultStake)},
          {label: "Cooldown", value: "7 days"},
          {label: "Ready at", value: hasPending ? new Date(releaseAt * 1000).toLocaleString() : "-"},
        ]}
      />
      {hasPending ? (
        <button
          type="button"
          disabled={!address || cooldownActive || withdrawing || withdrawWait.isLoading}
          onClick={() => withdraw({address: deployment.vault, abi: vaultAbi, functionName: "unstake"})}
          className={btnCls(!address || cooldownActive || withdrawing || withdrawWait.isLoading)}
        >
          {!address
            ? "Connect wallet"
            : cooldownActive
              ? "Cooldown active"
              : withdrawing || withdrawWait.isLoading
                ? "Withdrawing…"
                : "Withdraw stake"}
        </button>
      ) : (
        <button
          type="button"
          disabled={!address || !sharesWei || sharesWei === 0n || requesting || requestWait.isLoading}
          onClick={() => {
            if (!sharesWei) return;
            request({address: deployment.vault, abi: vaultAbi, functionName: "requestUnstake", args: [sharesWei]});
          }}
          className={btnCls(!address || !sharesWei || sharesWei === 0n || requesting || requestWait.isLoading)}
        >
          {!address
            ? "Connect wallet"
            : !sharesWei || sharesWei === 0n
              ? "Enter an amount"
              : requesting || requestWait.isLoading
                ? "Requesting…"
                : "Request unstake (7-day cooldown)"}
        </button>
      )}
      <TxStatus hash={withdrawTx ?? requestTx} />
    </>
  );
}

export function ClaimMode({deployment, address, user}: ModeProps) {
  const {writeContract, data: tx, isPending} = useWriteContract();
  const wait = useWaitForTransactionReceipt({hash: tx});
  const [p0, p1] = user.pendingRewards ?? [0n, 0n];
  const anyPending = p0 > 0n || p1 > 0n;

  return (
    <>
      <StatRow
        stats={[
          {label: `Pending ${deployment.token0Symbol}`, value: fmtAmount(p0)},
          {label: `Pending ${deployment.token1Symbol}`, value: fmtAmount(p1)},
          {label: "Your stake", value: fmtAmount(user.vaultStake)},
        ]}
      />
      <button
        type="button"
        disabled={!address || !anyPending || isPending || wait.isLoading}
        onClick={() => writeContract({address: deployment.vault, abi: vaultAbi, functionName: "claim"})}
        className={btnCls(!address || !anyPending || isPending || wait.isLoading)}
      >
        {!address
          ? "Connect wallet"
          : !anyPending
            ? "Nothing to claim"
            : isPending || wait.isLoading
              ? "Claiming…"
              : "Claim rewards"}
      </button>
      <TxStatus hash={tx} />
    </>
  );
}

function fmtRewardPair(pending: readonly [bigint, bigint] | undefined): string {
  if (!pending) return "-";
  return `${fmtAmount(pending[0], 18, 2)} / ${fmtAmount(pending[1], 18, 2)}`;
}
