import type {Metadata} from "next";
import Link from "next/link";

import {Footer} from "@/components/Footer";
import {Header} from "@/components/Header";

export const metadata: Metadata = {
  title: "Governance",
  description:
    "How WoolFi is administered: a multisig controls a bounded admin surface, URU is underwriting not voting, and the hook code is immutable after deployment.",
};

export default function GovernancePage() {
  return (
    <main className="flex min-h-screen flex-col bg-bg">
      <Header />

      <div className="mx-auto w-full max-w-3xl px-6 pt-14 pb-24">
        <p className="font-mono text-2xs uppercase tracking-[0.28em] text-signal">Governance</p>
        <h1 className="mt-4 font-display text-[52px] font-medium leading-[1.02] tracking-tight text-ink sm:text-[64px]">
          Who decides what.
        </h1>
        <p className="mt-8 text-[18px] leading-relaxed text-ink/85">
          WoolFi v1 is administered by one multisig on Robinhood Chain. There is no token
          vote, no proposal system, and no browser-based admin console. This page explains what
          that means in plain English.
        </p>

        <Group>
          <Q>Who runs WoolFi?</Q>
          <A>
            A single multisig wallet. A multisig is a smart contract that needs several separate
            signers to approve any transaction before it goes through. The specific signers,
            threshold, and recovery process are published in the launch record. In v1 that
            multisig is the only party that can change protocol settings.
          </A>
        </Group>

        <Group>
          <Q>What can the multisig do?</Q>
          <List>
            <Item>Authorize a new pool (from the fixed 16-pool catalog) and set its oracle bindings.</Item>
            <Item>Re-tune parameters of a live pool (fee schedule, tolerance, hard threshold) within audited bounds.</Item>
            <Item>Pause the whole hook in an emergency, stopping swaps and liquidity adds.</Item>
            <Item>Resolve a structural break once the underlying market has reconverged.</Item>
            <Item>Configure per-pool vault drawdown percentage and fee routing.</Item>
          </List>
        </Group>

        <Group>
          <Q>What can the multisig NOT do?</Q>
          <List>
            <Item>Move your LP shares or your vault stake into another account. Balances are held by the position manager and vault contracts, not by governance.</Item>
            <Item>Change the hook&apos;s code. The hook contract is immutable after deployment. Only its documented parameters and pool authorizations are configurable.</Item>
            <Item>Issue or redeem Robinhood Stock Tokens. The token issuer (RHJ) controls that, entirely off-chain of WoolFi.</Item>
            <Item>Waive the sequencer/oracle safety checks. Those are hard-coded in the adapters.</Item>
            <Item>Vote &quot;on your behalf&quot; using URU. Underwriting stake is not voting stake.</Item>
          </List>
        </Group>

        <Group>
          <Q>Where does URU fit?</Q>
          <A>
            URU is the asset deposited into per-pool underwriting vaults. Stakers earn a share
            of pool fees and bear structural-break drawdown risk. Holding or staking URU does
            not grant any WoolFi governance rights in v1. URU is underwriting capital, not a
            voting token.
          </A>
        </Group>

        <Group>
          <Q>Why not just launch a token vote?</Q>
          <A>
            Token votes work best when there is a large, engaged holder base and a decision
            surface that changes often. WoolFi v1 has a fixed 16-pool catalog and an audited
            parameter range; there is very little to vote about that a small multisig cannot
            handle faster and more safely. If the surface grows, so will governance.
          </A>
        </Group>

        <Group>
          <Q>How do I verify all of this myself?</Q>
          <A>
            Every parameter change is an on-chain transaction, so every action the multisig
            takes is public and permanent on Robinhood Chain. The contract addresses, the
            multisig address, and its signer set are published in the launch record. See{" "}
            <Link href="/docs" className="text-signal underline underline-offset-4 hover:text-ink">
              /docs
            </Link>{" "}
            for architecture and{" "}
            <a
              href="https://github.com/sp0oby/woolfi/blob/main/PROJECT_SPEC.md"
              target="_blank"
              rel="noreferrer"
              className="text-signal underline underline-offset-4 hover:text-ink"
            >
              PROJECT_SPEC.md
            </a>{" "}
            for the canonical spec.
          </A>
        </Group>

        <div className="mt-16 flex flex-wrap gap-3">
          <Link
            href="/app"
            className="inline-flex items-center gap-2 border border-signal bg-signal/10 px-6 py-3 font-mono text-2xs uppercase tracking-[0.24em] text-signal transition-colors hover:bg-signal/20"
          >
            Open the terminal
          </Link>
          <Link
            href="/docs"
            className="inline-flex items-center gap-2 border border-line bg-panel px-6 py-3 font-mono text-2xs uppercase tracking-[0.24em] text-ink transition-colors hover:border-line-strong"
          >
            Read the docs
          </Link>
        </div>
      </div>

      <Footer />
    </main>
  );
}

function Group({children}: {children: React.ReactNode}) {
  return <section className="mt-14 border-t border-line pt-8">{children}</section>;
}

function Q({children}: {children: React.ReactNode}) {
  return (
    <h2 className="font-display text-[24px] font-medium leading-tight text-ink sm:text-[28px]">
      {children}
    </h2>
  );
}

function A({children}: {children: React.ReactNode}) {
  return <p className="mt-4 text-[15px] leading-[1.7] text-ink/80">{children}</p>;
}

function List({children}: {children: React.ReactNode}) {
  return <ul className="mt-4 space-y-3 border-l border-line pl-5">{children}</ul>;
}

function Item({children}: {children: React.ReactNode}) {
  return <li className="text-[14px] leading-[1.7] text-ink/75">{children}</li>;
}
