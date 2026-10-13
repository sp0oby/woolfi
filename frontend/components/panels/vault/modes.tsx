"use client";

import {useEffect, useState} from "react";
import {useReadContract, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useApprovalShadow} from "@/hooks/useApprovalShadow";
import {useAllowance, useUserReads} from "@/hooks/usePool";
import {useWrongNetwork} from "@/hooks/useWrongNetwork";
import {erc20Abi, hookAbi, vaultAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {uruFromShares} from "@/lib/txGuards";
import {robinhood} from "@/lib/wagmi";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, StatRow, TxStatus} from "../atoms";
import {btnCls, parseAmount} from "../panelHelpers";

/** WoolFiUnderwritingVault.UNSTAKE_CLAIM_WINDOW: a matured request must be withdrawn within this. */
const UNSTAKE_CLAIM_WINDOW_SECONDS = 24 * 60 * 60;

type UserReads = ReturnType<typeof useUserReads>;
type ModeProps = {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
  user: UserReads;
  /** Vault `totalStaked` (URU) and `totalShares`, to value the user's shares in URU. */
  vaultStaked: bigint | undefined;
  vaultShares: bigint | undefined;
};

/** The user's vault shares valued in URU: shares * totalStaked / totalShares. */
function stakeValue(user: UserReads, vaultStaked: bigint | undefined, vaultShares: bigint | undefined): string {
  return fmtAmount(uruFromShares(user.vaultStake, vaultStaked, vaultShares));
}

export function StakeMode({
  deployment,
  address,
  amount,
  setAmount,
  user,
  vaultStaked,
  vaultShares,
}: ModeProps & {
  amount: string;
  setAmount: (value: string) => void;
}) {
  const {wrongNetwork} = useWrongNetwork();
  const amountWei = parseAmount(amount, 18);
  const allowance = useAllowance(deployment.stakingToken, address, deployment.vault);
  const {writeContract: approve, data: approveTx, isPending: approving} = useWriteContract();
  const {writeContract: stake, data: stakeTx, isPending: staking} = useWriteContract();
  const approveWait = useWaitForTransactionReceipt({hash: approveTx});
  const stakeWait = useWaitForTransactionReceipt({hash: stakeTx});

  // Optimistic allowance shadow while reads catch up to a confirmed approval. It only covers the
  // exact token/spender/amount approved; anything else relies on the on-chain read.
  const shadow = useApprovalShadow(approveTx, approveWait.isSuccess, allowance.refetch);
  const clearApproval = shadow.clear;
  useEffect(() => {
    if (stakeWait.isSuccess) clearApproval();
  }, [stakeWait.isSuccess, stakeTx, clearApproval]);
  const needsApproval =
    amountWei !== undefined &&
    (allowance.data ?? 0n) < amountWei &&
    !shadow.covers({token: deployment.stakingToken, spender: deployment.vault, amount: amountWei});
  const busy = approving || staking || approveWait.isLoading || stakeWait.isLoading;
  const disabled = !address || wrongNetwork || amountWei === undefined || amountWei === 0n || busy;

  return (
    <>
      <Field label="Stake" token={deployment.stakingSymbol} value={amount} onChange={setAmount} editable hint={`balance ${fmtAmount(user.stakingTokenBal)}`} />
      <StatRow
        stats={[
          {label: `Your stake (${deployment.stakingSymbol})`, value: stakeValue(user, vaultStaked, vaultShares)},
          {label: "Vault TVL", value: fmtAmount(vaultStaked)},
          {label: "Pending rewards", value: fmtRewardPair(user.pendingRewards, deployment)},
        ]}
      />
      <button
        type="button"
        disabled={disabled}
        onClick={() => {
          if (!amountWei || !address || wrongNetwork) return;
          if (needsApproval) {
            shadow.request({token: deployment.stakingToken, spender: deployment.vault, amount: amountWei});
            approve({
              chainId: robinhood.id,
              address: deployment.stakingToken,
              abi: erc20Abi,
              functionName: "approve",
              args: [deployment.vault, amountWei],
            });
          } else {
            stake({chainId: robinhood.id, address: deployment.vault, abi: vaultAbi, functionName: "stake", args: [amountWei]});
          }
        }}
        className={btnCls(disabled)}
      >
        {!address
          ? "Connect wallet"
          : wrongNetwork
            ? "Wrong network"
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
  vaultStaked,
  vaultShares,
}: ModeProps & {amount: string; setAmount: (value: string) => void}) {
  const {wrongNetwork} = useWrongNetwork();
  const sharesWei = parseAmount(amount, 18);
  const {writeContract: request, data: requestTx, isPending: requesting} = useWriteContract();
  const {writeContract: withdraw, data: withdrawTx, isPending: withdrawing} = useWriteContract();
  const requestWait = useWaitForTransactionReceipt({hash: requestTx});
  const withdrawWait = useWaitForTransactionReceipt({hash: withdrawTx});
  const pending = user.pendingUnstake;
  const releaseAt = pending ? Number(pending[1]) : 0;
  const expiresAt = releaseAt + UNSTAKE_CLAIM_WINDOW_SECONDS;
  const now = Math.floor(Date.now() / 1000);
  // A matured request lapses after the vault's claim window; the staker then requests again.
  const expired = !!pending && pending[0] > 0n && now > expiresAt;
  const hasPending = !!pending && pending[0] > 0n && !expired;
  const cooldownActive = hasPending && now < releaseAt;
  // The vault refuses to pay out while this pool has a detected but unconfirmed break, so stakers
  // cannot exit between detection and the drawdown it may lead to.
  const breakPendingRead = useReadContract({
    address: deployment.hook,
    abi: hookAbi,
    functionName: "isBreakPendingForVault",
    args: [deployment.vault],
    query: {enabled: hasPending, refetchInterval: 30_000},
  });
  const breakPending = breakPendingRead.data === true;
  const withdrawBlocked = !address || wrongNetwork || cooldownActive || breakPending || withdrawing || withdrawWait.isLoading;

  return (
    <>
      {hasPending ? (
        <div className="border border-line px-5 py-4">
          <div className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">
            Pending unstake
          </div>
          <div className="mt-1 font-mono text-[15px] text-white">{fmtAmount(pending[0])} shares</div>
          <div className="mt-2 font-mono text-[12px] text-muted">
            {cooldownActive
              ? `Ready in ${Math.max(0, releaseAt - now)}s`
              : breakPending
                ? "Paused while a structural break or price gap is being confirmed. If your 1-day withdrawal window closes meanwhile, request again."
                : `Ready to withdraw until ${new Date(expiresAt * 1000).toLocaleString()}`}
          </div>
        </div>
      ) : (
        <>
          {expired ? (
            <p className="font-mono text-[12px] text-amber-200/85">
              Your earlier request expired: withdrawals must happen within 1 day of the cooldown
              ending. Request again to restart the 2-day cooldown.
            </p>
          ) : null}
          <Field label="Request unstake" token="SHARES" value={amount} onChange={setAmount} editable hint={`your shares ${fmtAmount(user.vaultStake)}`} />
        </>
      )}
      <StatRow
        stats={[
          {label: `Your stake (${deployment.stakingSymbol})`, value: stakeValue(user, vaultStaked, vaultShares)},
          {label: "Your shares", value: fmtAmount(user.vaultStake)},
          {label: "Cooldown", value: "2 days, then 1 day to withdraw"},
          {label: "Ready at", value: hasPending ? new Date(releaseAt * 1000).toLocaleString() : "-"},
        ]}
      />
      {hasPending ? (
        <button
          type="button"
          disabled={withdrawBlocked}
          onClick={() => {
            if (wrongNetwork) return;
            withdraw({chainId: robinhood.id, address: deployment.vault, abi: vaultAbi, functionName: "unstake"});
          }}
          className={btnCls(withdrawBlocked)}
        >
          {!address
            ? "Connect wallet"
            : wrongNetwork
              ? "Wrong network"
            : cooldownActive
              ? "Cooldown active"
              : breakPending
                ? "Paused · break or gap being confirmed"
                : withdrawing || withdrawWait.isLoading
                ? "Withdrawing…"
                : "Withdraw stake"}
        </button>
      ) : (
        <button
          type="button"
          disabled={!address || wrongNetwork || !sharesWei || sharesWei === 0n || requesting || requestWait.isLoading}
          onClick={() => {
            if (!sharesWei || wrongNetwork) return;
            request({chainId: robinhood.id, address: deployment.vault, abi: vaultAbi, functionName: "requestUnstake", args: [sharesWei]});
          }}
          className={btnCls(!address || wrongNetwork || !sharesWei || sharesWei === 0n || requesting || requestWait.isLoading)}
        >
          {!address
            ? "Connect wallet"
            : wrongNetwork
              ? "Wrong network"
            : !sharesWei || sharesWei === 0n
              ? "Enter an amount"
              : requesting || requestWait.isLoading
                ? "Requesting…"
                : expired
                  ? "Request again (2-day cooldown)"
                  : "Request unstake (2-day cooldown)"}
        </button>
      )}
      <TxStatus hash={withdrawTx ?? requestTx} />
    </>
  );
}

export function ClaimMode({deployment, address, user, vaultStaked, vaultShares}: ModeProps) {
  const {wrongNetwork} = useWrongNetwork();
  const {writeContract, data: tx, isPending} = useWriteContract();
  const wait = useWaitForTransactionReceipt({hash: tx});
  const [p0, p1] = user.pendingRewards ?? [0n, 0n];
  const anyPending = p0 > 0n || p1 > 0n;

  return (
    <>
      <StatRow
        stats={[
          {label: `Pending ${deployment.token0Symbol}`, value: fmtAmount(p0, deployment.token0Decimals)},
          {label: `Pending ${deployment.token1Symbol}`, value: fmtAmount(p1, deployment.token1Decimals)},
          {label: `Your stake (${deployment.stakingSymbol})`, value: stakeValue(user, vaultStaked, vaultShares)},
        ]}
      />
      <button
        type="button"
        disabled={!address || wrongNetwork || !anyPending || isPending || wait.isLoading}
        onClick={() => {
          if (wrongNetwork) return;
          writeContract({chainId: robinhood.id, address: deployment.vault, abi: vaultAbi, functionName: "claim"});
        }}
        className={btnCls(!address || wrongNetwork || !anyPending || isPending || wait.isLoading)}
      >
        {!address
          ? "Connect wallet"
          : wrongNetwork
            ? "Wrong network"
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

function fmtRewardPair(
  pending: readonly [bigint, bigint] | undefined,
  deployment: WoolFiDeployment,
): string {
  if (!pending) return "-";
  return `${fmtAmount(pending[0], deployment.token0Decimals, 2)} / ${fmtAmount(pending[1], deployment.token1Decimals, 2)}`;
}
