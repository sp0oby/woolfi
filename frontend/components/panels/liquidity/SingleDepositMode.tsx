"use client";

import {useMemo, useState} from "react";
import {useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {useZapQuote} from "@/hooks/useZapQuote";
import {useAllowance} from "@/hooks/usePool";
import {erc20Abi, liquidityZapperAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {robinhoodAssets} from "@/lib/pools/assets";
import {poolKeyFor} from "@/lib/poolKey";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {Field, StatRow, TxStatus} from "../atoms";
import {btnCls, parseAmount} from "../panelHelpers";

const ZERO = "0x0000000000000000000000000000000000000000" as const;

type InputOption = {
  symbol: string;
  address: `0x${string}`;
  actualAddress: `0x${string}`;
  decimals: number;
  native?: boolean;
};

export function SingleDepositMode({
  deployment,
  address,
}: {
  deployment: WoolFiDeployment;
  address: `0x${string}` | undefined;
}) {
  const options = useMemo(() => inputOptions(deployment), [deployment]);
  const [selected, setSelected] = useState(options[0].symbol);
  const [amount, setAmount] = useState("");
  const option = options.find((item) => item.symbol === selected) ?? options[0];
  const amountWei = parseAmount(amount, option.decimals);
  const key = poolKeyFor(deployment);
  const zapper = deployment.liquidityZapper;
  const allowance = useAllowance(option.actualAddress, address, zapper);
  const {quote, error: quoteError, loading} = useZapQuote({
    deployment,
    key,
    tokenIn: option.actualAddress,
    amountIn: amountWei,
    account: address,
    enabled: !!zapper,
  });
  const {writeContract: approve, data: approvalHash, isPending: approving, error: approvalError} = useWriteContract();
  const {writeContract: zap, data: zapHash, isPending: zapping, error: zapError} = useWriteContract();
  const approvalReceipt = useWaitForTransactionReceipt({hash: approvalHash});
  const zapReceipt = useWaitForTransactionReceipt({hash: zapHash});
  const approved = option.native || (!!amountWei && (allowance.data ?? 0n) >= amountWei) || approvalReceipt.isSuccess;
  const busy = approving || zapping || approvalReceipt.isLoading || zapReceipt.isLoading;
  const ready = !!address && !!zapper && !!amountWei && amountWei > 0n && !!quote && !loading && !busy;
  const canApprove = !!address && !!zapper && !!amountWei && !option.native && !approved && !busy;
  const canZap = ready && approved;

  function submit() {
    if (!address || !zapper || !amountWei) return;
    if (!approved) {
      approve({
        address: option.actualAddress,
        abi: erc20Abi,
        functionName: "approve",
        args: [zapper, amountWei],
      });
      return;
    }
    if (!quote) return;
    zap({
      address: zapper,
      abi: liquidityZapperAbi,
      functionName: "zap",
      args: [{
        key,
        tokenIn: option.native ? ZERO : option.actualAddress,
        amountIn: amountWei,
        swap0: quote.swap0,
        swap1: quote.swap1,
        minShares: quote.shares * 9_900n / 10_000n,
        deadline: BigInt(Math.floor(Date.now() / 1_000) + 20 * 60),
        recipient: address,
      }],
      value: option.native ? amountWei : 0n,
    });
  }

  const error = quoteError ?? firstError(approvalError, zapError);
  return (
    <>
      <label className="block font-mono text-[10px] uppercase tracking-[0.18em] text-muted">
        Input asset
        <select
          value={selected}
          onChange={(event) => {
            setSelected(event.target.value);
            setAmount("");
          }}
          className="mt-2 w-full border border-line bg-black px-3 py-3 text-[12px] text-white"
        >
          {options.map((item) => <option key={item.symbol} value={item.symbol}>{item.symbol}</option>)}
        </select>
      </label>
      <Field label="Deposit" token={option.symbol} value={amount} onChange={setAmount} editable />
      <StatRow stats={[
        {label: "Expected shares", value: loading ? "Quoting…" : fmtAmount(quote?.shares)},
        {
          label: deployment.token0Symbol,
          value: fmtAmount(quote?.amount0, deployment.token0Decimals),
        },
        {
          label: deployment.token1Symbol,
          value: fmtAmount(quote?.amount1, deployment.token1Decimals),
        },
      ]} />
      {!zapper ? (
        <div className="border border-line px-5 py-4 text-[13px] leading-relaxed text-muted">
          One-token deposits activate only after the audited zapper and external Uniswap executor
          are receipt-verified in the production manifest.
        </div>
      ) : null}
      {error ? (
        <div className="border border-amber-200/30 bg-amber-200/[0.04] px-4 py-3 font-mono text-[12px] text-amber-100/95 break-words">
          {error.slice(0, 320)}
        </div>
      ) : null}
      <button type="button" disabled={!canApprove && !canZap} onClick={submit} className={btnCls(!canApprove && !canZap)}>
        {!address
          ? "Connect wallet"
          : !zapper
            ? "Zapper not deployed"
            : !amountWei
              ? "Enter amount"
              : !approved
                ? `Approve ${option.symbol}`
                : loading
                  ? "Finding best Uniswap route…"
                  : !quote
                    ? "No executable route"
                    : zapping || zapReceipt.isLoading
                      ? "Providing liquidity…"
                      : "Swap and provide liquidity"}
      </button>
      <TxStatus hash={zapHash ?? approvalHash} />
      <p className="font-mono text-[10px] leading-relaxed text-muted">
        The app compares direct and USDG/WETH-routed Uniswap v3 quotes. Each route and the final LP
        shares enforce 1% slippage bounds and a 20-minute deadline; unused input is refunded.
      </p>
    </>
  );
}

function inputOptions(deployment: WoolFiDeployment): InputOption[] {
  const raw: InputOption[] = [
    assetOption(deployment.token0),
    assetOption(deployment.token1),
    assetOption(robinhoodAssets.USDG.address),
    assetOption(robinhoodAssets.WETH.address),
    {
      symbol: "ETH",
      address: ZERO,
      actualAddress: robinhoodAssets.WETH.address,
      decimals: robinhoodAssets.WETH.decimals,
      native: true,
    },
  ];
  return raw.filter((item, index) => raw.findIndex((candidate) => candidate.symbol === item.symbol) === index);
}

function assetOption(address: `0x${string}`): InputOption {
  const asset = Object.values(robinhoodAssets).find(
    (item) => item.address.toLowerCase() === address.toLowerCase(),
  );
  if (!asset) throw new Error(`Unknown curated asset ${address}`);
  return {symbol: asset.symbol, address: asset.address, actualAddress: asset.address, decimals: asset.decimals};
}

function firstError(...errors: Array<Error | null>): string | undefined {
  const error = errors.find(Boolean) as (Error & {shortMessage?: string}) | undefined;
  return error?.shortMessage ?? error?.message;
}
