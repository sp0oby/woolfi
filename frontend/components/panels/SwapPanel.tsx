"use client";

import {useEffect, useState} from "react";
import {useAccount, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {erc20Abi, swapRouterAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import {useSelectedPool} from "@/hooks/useSelectedPool";
import {applySlippage, deadlineIn, DEFAULT_SLIPPAGE, parseSlippageBps} from "@/lib/txGuards";
import {robinhood} from "@/lib/wagmi";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {useApprovalShadow} from "@/hooks/useApprovalShadow";
import {useAllowance, usePoolReads, useUserReads} from "@/hooks/usePool";
import {useSwapQuote} from "@/hooks/useSwapQuote";
import {
  friendlySwapError,
  needsLiquidity,
  NO_LIQUIDITY_MESSAGE,
  openActionTab,
  SWAP_ADVERSARIAL_DURING_BREAK_MESSAGE,
} from "@/components/poolState";
import {Field, PanelFootnote, SlippageInput, StatRow, TxStatus} from "./atoms";
import {btnCls, parseAmount} from "./panelHelpers";

const ZERO_BYTES = "0x" as const;

/**
 * Swap UI wired to {WoolFiSwapRouter}. User-set slippage tolerance (capped at 5%) is applied to
 * the simulated output of the exact current inputs; swaps carry a 20-minute deadline.
 */
export function SwapPanel() {
  const {pool, deployment, wrongNetwork} = useSelectedPool();
  const {address} = useAccount();
  const {drift, safety, breakStatus, totalShares} = usePoolReads();
  const user = useUserReads(address);

  const [zeroForOne, setZeroForOne] = useState(true);
  const [amountIn, setAmountIn] = useState("");
  // 1.0% default - launch pools start with modest liquidity, so a typical swap moves price
  // meaningfully even before the asymmetric fee. The simulate-quote below makes this much less
  // brittle, but the default still needs to absorb the buffer between simulation and signing.
  const [slippage, setSlippage] = useState(DEFAULT_SLIPPAGE);

  if (!deployment) {
    return <PanelFootnote>{pool.base.symbol} / {pool.quote.symbol} is not deployed yet. All 18 pools open together at launch.</PanelFootnote>;
  }
  if (needsLiquidity(pool, totalShares)) {
    return (
      <div className="space-y-4">
        <div className="border border-warn/30 bg-warn/[0.05] px-4 py-3 font-mono text-[12px] text-ink/90">
          <div className="text-[10px] uppercase tracking-[0.18em] text-warn">Needs liquidity</div>
          <p className="mt-1.5 normal-case">{NO_LIQUIDITY_MESSAGE}</p>
        </div>
        <button type="button" onClick={() => openActionTab("provide")} className={btnCls(false)}>
          Provide liquidity
        </button>
      </div>
    );
  }
  if (!deployment.swapRouter) {
    return (
      <div className="space-y-5">
        <Field label="You pay" token={zeroForOne ? deployment.token0Symbol : deployment.token1Symbol} value={amountIn} onChange={setAmountIn} editable />
        <PanelFootnote>
          Swap router not yet deployed on this chain. Run{" "}
          <span className="text-ink">forge script script/DeployRouter.s.sol --broadcast</span> and
          the panel will activate.
        </PanelFootnote>
      </div>
    );
  }

  return (
    <Live
      deployment={deployment as WoolFiDeployment & {swapRouter: `0x${string}`}}
      address={address}
      wrongNetwork={wrongNetwork}
      drift={drift}
      safety={safety}
      broken={breakStatus?.broken ?? safety?.structurallyBroken === true}
      user={user}
      zeroForOne={zeroForOne}
      setZeroForOne={setZeroForOne}
      amountIn={amountIn}
      setAmountIn={setAmountIn}
      slippage={slippage}
      setSlippage={setSlippage}
    />
  );
}

function Live({
  deployment,
  address,
  wrongNetwork,
  drift,
  safety,
  broken,
  user,
  zeroForOne,
  setZeroForOne,
  amountIn,
  setAmountIn,
  slippage,
  setSlippage,
}: {
  deployment: WoolFiDeployment & {swapRouter: `0x${string}`};
  address: `0x${string}` | undefined;
  wrongNetwork: boolean;
  drift: bigint | undefined;
  safety: ReturnType<typeof usePoolReads>["safety"];
  broken: boolean;
  user: ReturnType<typeof useUserReads>;
  zeroForOne: boolean;
  setZeroForOne: (fn: (d: boolean) => boolean) => void;
  amountIn: string;
  setAmountIn: (v: string) => void;
  slippage: string;
  setSlippage: (v: string) => void;
}) {
  const key = poolKeyFor(deployment);
  const tokenIn = zeroForOne ? deployment.token0 : deployment.token1;
  const tokenInLabel = zeroForOne ? deployment.token0Symbol : deployment.token1Symbol;
  const tokenOutLabel = zeroForOne ? deployment.token1Symbol : deployment.token0Symbol;
  const balanceIn = zeroForOne ? user.bal0 : user.bal1;
  const tokenInDecimals = zeroForOne ? deployment.token0Decimals : deployment.token1Decimals;
  const tokenOutDecimals = zeroForOne ? deployment.token1Decimals : deployment.token0Decimals;

  const amountInWei = parseAmount(amountIn, tokenInDecimals);

  const allowance = useAllowance(tokenIn, address, deployment.swapRouter);
  const {writeContract: approve, data: approveTx, isPending: approving} = useWriteContract();
  const {writeContract: swap, data: swapTx, isPending: swapping} = useWriteContract();
  const approveWait = useWaitForTransactionReceipt({hash: approveTx});
  const swapWait = useWaitForTransactionReceipt({hash: swapTx});

  // Optimistic allowance shadow while the on-chain read lags the approval receipt. It only covers
  // the exact token, spender and amount that was approved; anything else uses the on-chain read.
  const shadow = useApprovalShadow(approveTx, approveWait.isSuccess, allowance.refetch);
  const wantedApproval =
    amountInWei !== undefined ? {token: tokenIn, spender: deployment.swapRouter, amount: amountInWei} : undefined;
  const clearApproval = shadow.clear;
  useEffect(() => {
    if (swapWait.isSuccess) clearApproval();
  }, [swapWait.isSuccess, swapTx, clearApproval]);

  const needsApproval =
    amountInWei !== undefined && (allowance.data ?? 0n) < amountInWei && !shadow.covers(wantedApproval);
  const slippageBps = parseSlippageBps(slippage);
  const busy = approving || swapping || approveWait.isLoading || swapWait.isLoading;

  // Real on-chain quote - only runs once allowance is sufficient (otherwise the simulation
  // reverts on transferFrom). When it succeeds, we know the exact amountOut the swap would
  // settle at, so the minOut calc below is meaningful instead of a bps-against-input guess.
  const {quote, error: quoteError, loading: quoting} = useSwapQuote({
    router: deployment.swapRouter,
    poolKey: key,
    zeroForOne,
    amountIn: needsApproval ? undefined : amountInWei,
    account: address,
  });

  // corrective when the swap pushes the pool toward fair price
  let direction = "-";
  if (drift !== undefined) {
    if (drift === 0n) direction = "in band";
    else if ((drift > 0n && zeroForOne) || (drift < 0n && !zeroForOne)) direction = "corrective";
    else direction = "adversarial";
  }
  void safety;
  const blockedByBreak = broken && direction === "adversarial";
  const friendlyQuoteError = friendlySwapError(quoteError);
  const ready =
    !!address &&
    !wrongNetwork &&
    !!amountInWei &&
    amountInWei > 0n &&
    slippageBps !== undefined &&
    !busy &&
    !blockedByBreak &&
    (needsApproval || (quote !== undefined && !quoting));

  function onClick() {
    if (!amountInWei || !address || slippageBps === undefined || wrongNetwork) return;
    if (needsApproval) {
      shadow.request({token: tokenIn, spender: deployment.swapRouter, amount: amountInWei});
      approve({
        chainId: robinhood.id,
        address: tokenIn,
        abi: erc20Abi,
        functionName: "approve",
        args: [deployment.swapRouter, amountInWei],
      });
      return;
    }
    // `quote` is only defined when it was simulated for exactly these inputs (see useSwapQuote).
    if (quote === undefined || quoting) return;
    // Slippage tolerance is applied to the *simulated* output, not to amountIn. That correctly
    // absorbs LP fee + asymmetric-fee surcharge + price impact, and only fails if the pool
    // state shifts between simulation and execution.
    const minOut = applySlippage(quote, slippageBps);
    swap({
      chainId: robinhood.id,
      address: deployment.swapRouter,
      abi: swapRouterAbi,
      functionName: "swap",
      args: [key, zeroForOne, amountInWei, minOut, address, ZERO_BYTES, deadlineIn(20)],
    });
  }

  return (
    <div className="space-y-5">
      <Field
        label="You pay"
        token={tokenInLabel}
        value={amountIn}
        onChange={setAmountIn}
        editable
        hint={`balance ${fmtAmount(balanceIn, tokenInDecimals)}`}
      />
      <div className="flex justify-center">
        <button
          type="button"
          onClick={() => setZeroForOne((d) => !d)}
          aria-label="Flip swap direction"
          title="Flip direction"
          className="font-mono text-muted hover:text-ink transition-colors text-lg leading-none px-3 py-1"
        >
          ⇅
        </button>
      </div>
      <Field
        label="You receive"
        token={tokenOutLabel}
        value={quote !== undefined ? fmtAmount(quote, tokenOutDecimals, 6) : ""}
        editable={false}
        hint={
          needsApproval
            ? "approve first to see a quote"
            : quoting
              ? "quoting…"
              : quote !== undefined && slippageBps !== undefined
                ? `min ${fmtAmount(applySlippage(quote, slippageBps), tokenOutDecimals, 6)} after slippage`
                : undefined
        }
      />

      <SlippageInput value={slippage} onChange={setSlippage} />

      <StatRow
        stats={[
          {label: "Pool drift (bps)", value: drift !== undefined ? signedBps(drift) : "-"},
          {label: "Direction", value: direction},
          {label: "Slippage", value: slippageBps !== undefined ? `${(Number(slippageBps) / 100).toFixed(2)}%` : "-"},
        ]}
      />

      {blockedByBreak ? (
        <div className="border border-danger/40 bg-danger/[0.06] px-4 py-3 font-mono text-[12px] text-ink/90">
          <div className="text-[10px] uppercase tracking-[0.18em] text-danger">Structural break</div>
          <p className="mt-1.5 normal-case">{SWAP_ADVERSARIAL_DURING_BREAK_MESSAGE}</p>
        </div>
      ) : quoteError && !needsApproval ? (
        <div className="border border-warn/30 bg-warn/[0.05] px-4 py-3 font-mono text-[12px] text-ink/90">
          <div className="text-[10px] uppercase tracking-[0.18em] text-warn">
            {friendlyQuoteError ? "Trade not possible right now" : "Quote failed"}
          </div>
          <p className="mt-1.5 normal-case break-words">{friendlyQuoteError ?? quoteError.slice(0, 320)}</p>
        </div>
      ) : null}

      <button type="button" disabled={!ready} onClick={onClick} className={btnCls(!ready)}>
        {blockedByBreak
          ? "Only corrective trades during a break"
          : !address
          ? "Connect wallet"
          : wrongNetwork
            ? "Wrong network"
          : !amountInWei || amountInWei === 0n
            ? "Enter an amount"
            : slippageBps === undefined
              ? "Set slippage (max 5%)"
              : approving || approveWait.isLoading
                ? "Approving…"
                : swapping || swapWait.isLoading
                  ? "Swapping…"
                  : needsApproval
                    ? `Approve ${tokenInLabel}`
                    : quoting
                      ? "Quoting…"
                      : quote === undefined
                        ? friendlyQuoteError
                          ? "Try a smaller amount"
                          : "Cannot quote swap"
                        : "Swap"}
      </button>
      <TxStatus hash={swapTx ?? approveTx} />

      <PanelFootnote>
        Trades that move the pool toward the Chainlink price pay less than the base fee; trades
        that move it away pay more. A single trade cannot push the price more than the hard
        threshold away from Chainlink. The router enforces your minimum output.
      </PanelFootnote>
    </div>
  );
}

function signedBps(bps: bigint): string {
  return `${bps > 0n ? "+" : ""}${bps.toString()}`;
}
