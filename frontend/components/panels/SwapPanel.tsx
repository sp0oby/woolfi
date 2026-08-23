"use client";

import {useEffect, useState} from "react";
import {parseUnits} from "viem";
import {useAccount, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {erc20Abi, swapRouterAbi} from "@/lib/abis";
import {fmtAmount} from "@/lib/format";
import {poolKeyFor} from "@/lib/poolKey";
import {useSelectedPool} from "@/hooks/useSelectedPool";
import type {WoolFiDeployment} from "@/lib/woolfi";

import {useAllowance, usePoolReads, useUserReads} from "@/hooks/usePool";
import {useSwapQuote} from "@/hooks/useSwapQuote";
import {Field, PanelFootnote, StatRow, TxStatus} from "./atoms";

const ZERO_BYTES = "0x" as const;

/**
 * Swap UI wired to {WoolFiSwapRouter}. User-set slippage tolerance (% bps); we pass
 * `amountOutMinimum = amountIn * (10000 - slippageBps) / 10000` as a first-cut bound. A future
 * pass will quote the asymmetric fee from the hook for a tighter min-out.
 */
export function SwapPanel() {
  const {pool, deployment} = useSelectedPool();
  const {address} = useAccount();
  const {drift, safety} = usePoolReads();
  const user = useUserReads(address);

  const [zeroForOne, setZeroForOne] = useState(true);
  const [amountIn, setAmountIn] = useState("");
  // 1.0% default - low pool liquidity on testnet means a typical swap moves price meaningfully
  // even before the asymmetric fee. The simulate-quote below makes this much less brittle, but
  // the default still needs to absorb the buffer between simulation and signing.
  const [slippage, setSlippage] = useState("1.0");

  if (!deployment) {
    return <PanelFootnote>{pool.base.symbol} / {pool.quote.symbol} is fully catalogued, but trading stays disabled until its verified oracle and protocol deployment are live.</PanelFootnote>;
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
      drift={drift}
      safety={safety}
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
  drift,
  safety,
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
  drift: bigint | undefined;
  safety: ReturnType<typeof usePoolReads>["safety"];
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

  const amountInWei = parseAmount(amountIn, 18);

  const allowance = useAllowance(tokenIn, address, deployment.swapRouter);
  const {writeContract: approve, data: approveTx, isPending: approving} = useWriteContract();
  const {writeContract: swap, data: swapTx, isPending: swapping} = useWriteContract();
  const approveWait = useWaitForTransactionReceipt({hash: approveTx});
  const swapWait = useWaitForTransactionReceipt({hash: swapTx});

  // Optimistic allowance shadow - same fix as LiquidityPanel/VaultPanel. Without this the
  // on-chain allowance read lags the receipt and the button gets stuck on "Approve".
  // Keyed by tokenIn so flipping direction resets it.
  const [optAllow, setOptAllow] = useState<{token: `0x${string}` | undefined; amount: bigint}>({
    token: undefined,
    amount: 0n,
  });
  useEffect(() => {
    if (
      approveWait.isSuccess &&
      amountInWei !== undefined &&
      (optAllow.token !== tokenIn || amountInWei > optAllow.amount)
    ) {
      setOptAllow({token: tokenIn, amount: amountInWei});
      allowance.refetch();
    }
  }, [approveWait.isSuccess, amountInWei, tokenIn, allowance, optAllow]);
  const effAllow =
    optAllow.token === tokenIn && optAllow.amount > (allowance.data ?? 0n)
      ? optAllow.amount
      : (allowance.data ?? 0n);

  const needsApproval = amountInWei !== undefined && effAllow < amountInWei;
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
  const blockedByBreak = safety?.structurallyBroken === true && direction === "adversarial";
  const ready =
    !!address &&
    !!amountInWei &&
    amountInWei > 0n &&
    slippageBps !== undefined &&
    !busy &&
    !blockedByBreak &&
    (needsApproval || quote !== undefined);

  function onClick() {
    if (!amountInWei || !address || slippageBps === undefined) return;
    if (needsApproval) {
      approve({
        address: tokenIn,
        abi: erc20Abi,
        functionName: "approve",
        args: [deployment.swapRouter, amountInWei],
      });
      return;
    }
    if (quote === undefined) return;
    // Slippage tolerance is applied to the *simulated* output, not to amountIn. That correctly
    // absorbs LP fee + asymmetric-fee surcharge + price impact, and only fails if the pool
    // state shifts between simulation and execution.
    const minOut = (quote * (10_000n - slippageBps)) / 10_000n;
    swap({
      address: deployment.swapRouter,
      abi: swapRouterAbi,
      functionName: "swap",
      args: [key, zeroForOne, amountInWei, minOut, address, ZERO_BYTES],
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
        hint={`balance ${fmtAmount(balanceIn)}`}
      />
      <div className="flex justify-center">
        <button
          type="button"
          onClick={() => setZeroForOne((d) => !d)}
          aria-label="Flip swap direction"
          className="font-mono text-muted hover:text-ink transition-colors text-lg leading-none px-3 py-1"
        >
          ↓
        </button>
      </div>
      <Field
        label="You receive"
        token={tokenOutLabel}
        value={quote !== undefined ? formatQuote(quote) : ""}
        editable={false}
        hint={
          needsApproval
            ? "approve first to see a quote"
            : quoting
              ? "quoting…"
              : quote !== undefined && slippageBps !== undefined
                ? `min ${formatQuote((quote * (10_000n - slippageBps)) / 10_000n)} after slippage`
                : undefined
        }
      />

      <div className="flex items-baseline justify-between gap-3 border border-line px-5 py-3">
        <span className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted">Slippage (%)</span>
        <input
          type="text"
          inputMode="decimal"
          value={slippage}
          onChange={(e) => setSlippage(e.target.value.replace(/[^0-9.]/g, ""))}
          className="bg-transparent font-mono text-sm text-white outline-none text-right w-24"
        />
      </div>

      <StatRow
        stats={[
          {label: "Pool drift (bps)", value: drift !== undefined ? signedBps(drift) : "-"},
          {label: "Direction", value: direction},
          {label: "Slippage", value: slippageBps !== undefined ? `${(Number(slippageBps) / 100).toFixed(2)}%` : "-"},
        ]}
      />

      {quoteError && !needsApproval ? (
        <div className="border border-amber-200/30 bg-amber-200/[0.04] px-4 py-3 font-mono text-[12px] text-amber-100/95">
          <div className="uppercase tracking-[0.18em] text-[10px] text-amber-200/85">Quote failed</div>
          <p className="mt-1.5 normal-case break-words">{quoteError.slice(0, 320)}</p>
        </div>
      ) : null}

      <button type="button" disabled={!ready} onClick={onClick} className={btnCls(!ready)}>
        {blockedByBreak
          ? "Adversarial swap blocked"
          : !address
          ? "Connect wallet"
          : !amountInWei || amountInWei === 0n
            ? "Enter an amount"
            : slippageBps === undefined
              ? "Set slippage"
              : approving || approveWait.isLoading
                ? "Approving…"
                : swapping || swapWait.isLoading
                  ? "Swapping…"
                  : needsApproval
                    ? `Approve ${tokenInLabel}`
                    : quoting
                      ? "Quoting…"
                      : quote === undefined
                        ? "Cannot quote swap"
                        : "Swap"}
      </button>
      <TxStatus hash={swapTx ?? approveTx} />

      <PanelFootnote>
        Swap routes through {`{WoolFiSwapRouter}`}. The WoolFi hook decides the asymmetric fee in
        beforeSwap - corrective swaps are discounted, adversarial swaps are surcharged.
      </PanelFootnote>
    </div>
  );
}

function parseAmount(v: string, decimals: number): bigint | undefined {
  if (!v || v === "." || v.startsWith(".")) return undefined;
  try {
    return parseUnits(v as `${number}`, decimals);
  } catch {
    return undefined;
  }
}

function formatQuote(wei: bigint): string {
  // Display ~6 significant decimals - keep tight enough to read, sparse enough to fit the panel.
  const whole = wei / 10n ** 18n;
  const frac = wei % 10n ** 18n;
  const fracStr = frac.toString().padStart(18, "0").slice(0, 6).replace(/0+$/, "");
  return fracStr.length > 0 ? `${whole}.${fracStr}` : whole.toString();
}

function parseSlippageBps(v: string): bigint | undefined {
  if (!v) return undefined;
  const num = Number(v);
  if (!Number.isFinite(num) || num < 0 || num > 50) return undefined;
  // 0.5 -> 50 bps
  return BigInt(Math.floor(num * 100));
}

function signedBps(bps: bigint): string {
  return `${bps > 0n ? "+" : ""}${bps.toString()}`;
}

function btnCls(disabled: boolean) {
  return `block w-full py-3 border border-line font-mono text-[11px] uppercase tracking-[0.22em] transition-colors ${
    disabled ? "text-muted cursor-not-allowed" : "text-white hover:bg-white/5"
  }`;
}
