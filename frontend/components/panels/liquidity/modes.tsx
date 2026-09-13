"use client";

import {useEffect, useState} from "react";
import {useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useLiquidityPreview} from "@/hooks/useLiquidityPreview";
import {useAllowance, useUserReads} from "@/hooks/usePool";
import {erc20Abi, pmAbi, wethAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, StatRow, TxStatus} from "../atoms";
import {btnCls, parseAmount} from "../panelHelpers";
import {SingleDepositMode} from "./SingleDepositMode";

type UserReads = ReturnType<typeof useUserReads>;
export {WithdrawMode} from "./WithdrawMode";

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
  price0,
  price1,
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
  price0: bigint | undefined;
  price1: bigint | undefined;
}) {
  const key = poolKeyFor(deployment);
  const a0Wei = parseAmount(a0, deployment.token0Decimals);
  const a1Wei = parseAmount(a1, deployment.token1Decimals);
  const [fundingMode, setFundingMode] = useState<"balanced" | "single">("balanced");
  const wethLeg = deployment.token0Symbol === "WETH" ? 0 : deployment.token1Symbol === "WETH" ? 1 : undefined;
  const [useEth, setUseEth] = useState(false);
  const [wrappedAmount, setWrappedAmount] = useState(0n);
  const allow0 = useAllowance(deployment.token0, address, deployment.positionManager);
  const allow1 = useAllowance(deployment.token1, address, deployment.positionManager);
  const {writeContract: approve0, data: tx0, isPending: pending0, error: approve0Error} = useWriteContract();
  const {writeContract: approve1, data: tx1, isPending: pending1, error: approve1Error} = useWriteContract();
  const {writeContract: mint, data: txMint, isPending: pendingMint, error: mintError} = useWriteContract();
  const {writeContract: wrap, data: txWrap, isPending: pendingWrap, error: wrapError} = useWriteContract();
  const wait0 = useWaitForTransactionReceipt({hash: tx0});
  const wait1 = useWaitForTransactionReceipt({hash: tx1});
  const waitMint = useWaitForTransactionReceipt({hash: txMint});
  const waitWrap = useWaitForTransactionReceipt({hash: txWrap});

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
  const wethAmount = wethLeg === 0 ? a0Wei : wethLeg === 1 ? a1Wei : undefined;
  useEffect(() => {
    if (waitWrap.isSuccess && wethAmount && wethAmount > wrappedAmount) setWrappedAmount(wethAmount);
  }, [waitWrap.isSuccess, wethAmount, wrappedAmount]);
  useEffect(() => {
    if (waitMint.isSuccess) setWrappedAmount(0n);
  }, [waitMint.isSuccess]);
  const needsWrap = useEth && wethAmount !== undefined && wrappedAmount < wethAmount;
  const busy =
    pending0 || pending1 || pendingMint || pendingWrap ||
    wait0.isLoading || wait1.isLoading || waitMint.isLoading || waitWrap.isLoading;
  const preview = useLiquidityPreview({
    positionManager: deployment.positionManager,
    poolKey: key,
    amount0: a0Wei,
    amount1: a1Wei,
    account: address,
    enabled: !needs0 && !needs1 && !needsWrap,
  });

  function onClick() {
    if (!a0Wei || !a1Wei || !address) return;
    if (needsWrap && wethAmount) {
      wrap({
        address: wethLeg === 0 ? deployment.token0 : deployment.token1,
        abi: wethAbi,
        functionName: "deposit",
        value: wethAmount,
      });
      return;
    }
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
    if (preview.shares === undefined) return;
    const minShares = preview.shares * 9_900n / 10_000n;
    const deadline = BigInt(Math.floor(Date.now() / 1_000) + 20 * 60);
    mint({
      address: deployment.positionManager,
      abi: pmAbi,
      functionName: "mint",
      args: [key, a0Wei, a1Wei, minShares, deadline, address],
    });
  }

  const ready = fundingMode === "balanced" && !!a0Wei && !!a1Wei && !!address && !busy &&
    (needsWrap || needs0 || needs1 || preview.shares !== undefined);
  return (
    <>
      <div className="grid grid-cols-2 border border-line p-1 font-mono text-[10px] uppercase tracking-[0.18em]">
        {(["balanced", "single"] as const).map((item) => (
          <button key={item} type="button" onClick={() => setFundingMode(item)}
            className={`px-3 py-2 ${fundingMode === item ? "bg-white/[0.06] text-white" : "text-muted"}`}>
            {item === "balanced" ? "Balanced" : "One token"}
          </button>
        ))}
      </div>
      {fundingMode === "single" ? (
        <SingleDepositMode deployment={deployment} address={address} />
      ) : (
        <>
          <Field label="Deposit" token={deployment.token0Symbol} value={a0} onChange={setA0} editable hint={`balance ${fmtAmount(user.bal0, deployment.token0Decimals)}`} />
          <Field label="Deposit" token={deployment.token1Symbol} value={a1} onChange={setA1} editable hint={`balance ${fmtAmount(user.bal1, deployment.token1Decimals)}`} />
          {wethLeg !== undefined ? (
            <label className="flex items-center gap-3 font-mono text-[11px] text-muted">
              <input type="checkbox" checked={useEth} onChange={(event) => setUseEth(event.target.checked)} />
              Wrap native ETH into the WETH deposit
            </label>
          ) : null}
          <StatRow
            stats={[
          {label: "Your LP shares", value: fmtAmount(user.lpShares)},
          {label: "Deposit ratio", value: depositRatio(a0Wei, a1Wei, price0, price1, deployment.token0Decimals, deployment.token1Decimals)},
          {label: "LP entry fee", value: "0"},
            ]}
          />
          <StatRow stats={[
            {label: "Expected shares", value: preview.loading ? "Simulating…" : fmtAmount(preview.shares)},
            {label: "Pool drift (bps)", value: drift !== undefined ? signedBps(drift) : "-"},
            {label: "Total LP shares", value: fmtAmount(totalShares)},
          ]} />
          {preview.error || wrapError || approve0Error || approve1Error || mintError ? (
            <div className="border border-amber-200/30 bg-amber-200/[0.04] px-4 py-3 font-mono text-[12px] text-amber-100/95 break-words">
              {(preview.error ?? firstError(wrapError, approve0Error, approve1Error, mintError)).slice(0, 320)}
            </div>
          ) : null}
          <button type="button" disabled={!ready} onClick={onClick} className={btnCls(!ready)}>
            {!address
          ? "Connect wallet"
          : !a0Wei || !a1Wei
            ? "Enter amounts"
            : pendingWrap || waitWrap.isLoading
              ? "Wrapping ETH…"
              : needsWrap
                ? "Wrap ETH"
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
                    : preview.loading
                      ? "Simulating…"
                      : preview.shares === undefined
                        ? "Cannot simulate deposit"
                        : "Provide liquidity"}
          </button>
          <TxStatus hash={txMint ?? tx1 ?? tx0 ?? txWrap} />
          <p className="font-mono text-[10px] leading-relaxed text-muted">
            The share preview uses the current pool price. Deposits enforce a 1% minimum-share
            bound and expire after 20 minutes.
          </p>
        </>
      )}
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

function depositRatio(
  amount0: bigint | undefined,
  amount1: bigint | undefined,
  price0: bigint | undefined,
  price1: bigint | undefined,
  decimals0: number,
  decimals1: number,
): string {
  if (!amount0 || !amount1 || !price0 || !price1) return "-";
  const value0 = amount0 * price0 / 10n ** BigInt(decimals0);
  const value1 = amount1 * price1 / 10n ** BigInt(decimals1);
  const total = value0 + value1;
  if (total === 0n) return "-";
  const pct0 = Number(value0 * 10_000n / total) / 100;
  return `${pct0.toFixed(1)}% / ${(100 - pct0).toFixed(1)}%`;
}

function firstError(...errors: Array<Error | null>): string {
  const error = errors.find(Boolean) as (Error & {shortMessage?: string}) | undefined;
  return error?.shortMessage ?? error?.message ?? "Transaction failed";
}
