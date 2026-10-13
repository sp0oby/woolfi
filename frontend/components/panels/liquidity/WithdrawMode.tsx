"use client";

import {useState} from "react";
import {maxUint256} from "viem";
import {useSimulateContract, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useUserReads} from "@/hooks/usePool";
import {useWrongNetwork} from "@/hooks/useWrongNetwork";
import {pmAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import {applySlippage, deadlineIn, DEFAULT_SLIPPAGE, parseSlippageBps} from "@/lib/txGuards";
import {robinhood} from "@/lib/wagmi";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, SlippageInput, StatRow, TxStatus} from "../atoms";
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
  const {wrongNetwork} = useWrongNetwork();
  const sharesWei = parseAmount(sharesIn, 18);
  const [slippage, setSlippage] = useState(DEFAULT_SLIPPAGE);
  const slippageBps = parseSlippageBps(slippage);
  const {writeContract: burn, data: tx, isPending} = useWriteContract();
  const wait = useWaitForTransactionReceipt({hash: tx});
  const {writeContract: collect, data: ctx, isPending: collectPending} = useWriteContract();
  const collectWait = useWaitForTransactionReceipt({hash: ctx});
  const validShares = sharesWei !== undefined && sharesWei > 0n;
  const tooMany = validShares && user.lpShares !== undefined && sharesWei > user.lpShares;

  // Estimate what the burn returns by simulating it as the owner with zero mins. The simulation
  // uses a far deadline so its query key stays stable; the real call gets a 20-minute one. The
  // query is keyed by its args, so the estimate always belongs to the shares currently entered.
  const estimate = useSimulateContract({
    chainId: robinhood.id,
    address: deployment.positionManager,
    abi: pmAbi,
    functionName: "burn",
    args: address && sharesWei ? [key, sharesWei, 0n, 0n, maxUint256, address] : undefined,
    account: address,
    query: {enabled: !!address && validShares && !tooMany, refetchInterval: 12_000},
  });
  const expected = estimate.data?.result as readonly [bigint, bigint] | undefined;
  const estimating = validShares && !tooMany && !!address && estimate.isFetching && !expected;

  const ready =
    !!address &&
    !wrongNetwork &&
    validShares &&
    !tooMany &&
    slippageBps !== undefined &&
    expected !== undefined &&
    !isPending &&
    !wait.isLoading;
  const collectDisabled = !address || wrongNetwork || collectPending || collectWait.isLoading;

  return (
    <>
      <Field label="Burn" token="LP shares" value={sharesIn} onChange={setShares} editable hint={`your shares ${fmtAmount(user.lpShares)}`} />
      <SlippageInput value={slippage} onChange={setSlippage} />
      <StatRow stats={[
        {label: "Your LP shares", value: fmtAmount(user.lpShares)},
        {label: `Pending ${deployment.token0Symbol}`, value: fmtAmount(user.pendingLpFees?.[0], deployment.token0Decimals)},
        {label: `Pending ${deployment.token1Symbol}`, value: fmtAmount(user.pendingLpFees?.[1], deployment.token1Decimals)},
      ]} />
      <StatRow stats={[
        {label: `Est. ${deployment.token0Symbol} out`, value: estimating ? "Simulating…" : fmtAmount(expected?.[0], deployment.token0Decimals)},
        {label: `Est. ${deployment.token1Symbol} out`, value: estimating ? "Simulating…" : fmtAmount(expected?.[1], deployment.token1Decimals)},
      ]} />
      <button
        type="button"
        disabled={!ready}
        onClick={() => {
          if (!sharesWei || !address || !expected || slippageBps === undefined || wrongNetwork) return;
          burn({
            chainId: robinhood.id,
            address: deployment.positionManager,
            abi: pmAbi,
            functionName: "burn",
            args: [
              key,
              sharesWei,
              applySlippage(expected[0], slippageBps),
              applySlippage(expected[1], slippageBps),
              deadlineIn(20),
              address,
            ],
          });
        }}
        className={btnCls(!ready)}
      >
        {!address
          ? "Connect wallet"
          : wrongNetwork
            ? "Wrong network"
            : !validShares
              ? "Enter shares"
              : tooMany
                ? "Exceeds your shares"
                : slippageBps === undefined
                  ? "Set slippage (max 5%)"
                  : isPending || wait.isLoading
                    ? "Withdrawing…"
                    : estimating
                      ? "Simulating…"
                      : expected === undefined
                        ? "Cannot estimate withdrawal"
                        : "Withdraw"}
      </button>
      <button
        type="button"
        disabled={collectDisabled}
        onClick={() => {
          if (!address || wrongNetwork) return;
          collect({chainId: robinhood.id, address: deployment.positionManager, abi: pmAbi, functionName: "collectFees", args: [key, address]});
        }}
        className={btnCls(collectDisabled)}
      >
        {!address
          ? "Connect wallet"
          : wrongNetwork
            ? "Wrong network"
            : collectPending || collectWait.isLoading
              ? "Collecting…"
              : "Collect fees only"}
      </button>
      <TxStatus hash={ctx ?? tx} />
      <p className="font-mono text-[10px] leading-relaxed text-muted">
        Withdrawals enforce minimum token amounts from a simulated burn, less your slippage, and
        expire after 20 minutes.
      </p>
    </>
  );
}
