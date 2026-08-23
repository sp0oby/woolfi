"use client";

import {useState} from "react";
import {useAccount} from "wagmi";

import {usePoolReads, useUserReads} from "@/hooks/usePool";
import {useSelectedPool} from "@/hooks/useSelectedPool";

import {PanelFootnote} from "./atoms";
import {ModeTabs} from "./panelHelpers";
import {ClaimMode, StakeMode, UnstakeMode} from "./vault/modes";

type Mode = "stake" | "unstake" | "claim";

const modes: readonly {id: Mode; label: string}[] = [
  {id: "stake", label: "Stake"},
  {id: "unstake", label: "Unstake"},
  {id: "claim", label: "Claim"},
];

export function VaultPanel() {
  const {pool, deployment} = useSelectedPool();
  const {address} = useAccount();
  const {vaultStaked} = usePoolReads();
  const user = useUserReads(address);
  const [mode, setMode] = useState<Mode>("stake");
  const [amount, setAmount] = useState("");

  if (!deployment) {
    return <PanelFootnote>URU staking for {pool.base.symbol} / {pool.quote.symbol} activates only when this pool and its underwriting vault are live.</PanelFootnote>;
  }

  return (
    <div className="space-y-5">
      <ModeTabs mode={mode} modes={modes} setMode={setMode} />
      {mode === "stake" ? (
        <StakeMode
          deployment={deployment}
          address={address}
          amount={amount}
          setAmount={setAmount}
          user={user}
          vaultStaked={vaultStaked}
        />
      ) : mode === "unstake" ? (
        <UnstakeMode
          deployment={deployment}
          address={address}
          amount={amount}
          setAmount={setAmount}
          user={user}
        />
      ) : (
        <ClaimMode deployment={deployment} address={address} user={user} />
      )}
      <PanelFootnote>
        {deployment.stakingSymbol} stakers underwrite structural-break risk: on a break the hook
        seizes a fraction of staked {deployment.stakingSymbol} and every staker takes a pro-rata
        haircut. In return, stakers earn a governance-configured share of pool swap fees in{" "}
        {deployment.token0Symbol}/{deployment.token1Symbol}.
      </PanelFootnote>
    </div>
  );
}
