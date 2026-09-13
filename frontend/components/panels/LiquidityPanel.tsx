"use client";

import Link from "next/link";
import {useState} from "react";
import {useAccount} from "wagmi";

import {usePoolReads, useUserReads} from "@/hooks/usePool";
import {useSelectedPool} from "@/hooks/useSelectedPool";

import {PanelFootnote} from "./atoms";
import {DepositMode, WithdrawMode} from "./liquidity/modes";
import {ModeTabs} from "./panelHelpers";

type Mode = "deposit" | "withdraw";

const modes: readonly {id: Mode; label: string}[] = [
  {id: "deposit", label: "Deposit"},
  {id: "withdraw", label: "Withdraw"},
];

export function LiquidityPanel() {
  const {pool, deployment} = useSelectedPool();
  const {address} = useAccount();
  const user = useUserReads(address);
  const {drift, totalShares, marketOpen, safety, price0, price1} = usePoolReads();
  const depositsBlocked =
    marketOpen === false ||
    safety?.structurallyBroken === true ||
    safety?.stabilizing === true ||
    safety?.oracleSkewed === true;
  const [mode, setMode] = useState<Mode>("deposit");
  const [amount0, setAmount0] = useState("");
  const [amount1, setAmount1] = useState("");
  const [shares, setShares] = useState("");

  if (!deployment) {
    return <PanelFootnote>Liquidity actions for {pool.base.symbol} / {pool.quote.symbol} are disabled while this curated pool is pending deployment.</PanelFootnote>;
  }

  return (
    <div className="space-y-5">
      <ModeTabs mode={mode} modes={modes} setMode={setMode} />
      {mode === "deposit" ? (
        depositsBlocked ? (
          <ClosedDeposits
            reason={
              safety?.structurallyBroken
                ? "Deposits paused · structural break"
                : safety?.stabilizing
                  ? "Deposits paused · opening stabilization"
                  : safety?.oracleSkewed
                    ? "Deposits paused · oracle skew"
                    : "Deposits paused · market closed"
            }
          />
        ) : (
          <DepositMode
            deployment={deployment}
            address={address}
            a0={amount0}
            setA0={setAmount0}
            a1={amount1}
            setA1={setAmount1}
            user={user}
            drift={drift}
            totalShares={totalShares}
            price0={price0}
            price1={price1}
          />
        )
      ) : (
        <WithdrawMode
          deployment={deployment}
          address={address}
          sharesIn={shares}
          setShares={setShares}
          user={user}
        />
      )}
      <PanelFootnote>
        LP shares are non-transferable in v1 and back the pool position 1:1 with the v4 liquidity
        you provide. Deposits are accepted only while the pool is in band and the equity market is
        open; withdrawals are always allowed (even out of band).
      </PanelFootnote>
    </div>
  );
}

function ClosedDeposits({reason}: {reason: string}) {
  return (
    <div className="border border-amber-200/30 bg-amber-200/[0.04] px-5 py-4">
      <div className="font-mono text-[10px] uppercase tracking-[0.22em] text-amber-200/85">
        {reason}
      </div>
      <p className="mt-2 text-[13px] leading-relaxed text-amber-50/85">
        Reopens next NYSE session. Withdrawals stay open.{" "}
        <Link href="/docs#market-hours" className="underline underline-offset-4 hover:text-white">
          Why →
        </Link>
      </p>
    </div>
  );
}
