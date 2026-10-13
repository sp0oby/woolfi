"use client";

import {useAccount} from "wagmi";

import {useGemuBalance} from "@/hooks/usePool";
import {gemuEligibilityText} from "@/lib/rebate";

/** Rebate eligibility for the connected wallet: does it hold an Urufu Gemu NFT? */
export function GemuEligibility({compact = false}: {compact?: boolean}) {
  const {address} = useAccount();
  const {balance, isLoading, isError} = useGemuBalance(address);
  const {text, eligible} = gemuEligibilityText({connected: !!address, balance, isLoading, isError});

  if (compact) return <span className={eligible ? "text-pos" : undefined}>{text}</span>;

  return (
    <div
      className={`border px-5 py-3 font-mono text-[11px] uppercase tracking-[0.18em] ${
        eligible ? "border-pos/30 bg-pos/[0.05] text-pos" : "border-line text-muted"
      }`}
    >
      {text}
    </div>
  );
}
