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
            threshold, and recovery process are published in the launch record. The multisig
            does not change settings directly: it proposes changes to a timelock, which holds
            each one in public for 3 days before it can run.
          </A>
        </Group>

        <Group>
          <Q>What can the multisig do?</Q>
          <List>
            <Item>Authorize a new pool (from the fixed 18-pool catalog) and set its oracle bindings.</Item>
            <Item>Re-tune parameters of a live pool (fee schedule, tolerance, hard threshold) within audited bounds.</Item>
            <Item>Pause the whole hook in an emergency, stopping swaps and liquidity adds. This is the one action that takes effect instantly; unpausing waits 3 days like everything else.</Item>
            <Item>Resolve a structural break directly, or change how long a break waits before it can be confirmed (up to one day).</Item>
            <Item>Configure per-pool vault drawdown percentage and fee routing.</Item>
          </List>
        </Group>

        <Group>
          <Q>What can the multisig NOT do?</Q>
          <List>
            <Item>Move your LP shares or your vault stake into another account. Balances are held by the position manager and vault contracts, not by governance.</Item>
            <Item>Change the hook&apos;s code. The hook contract is immutable after deployment. Only its documented parameters and pool authorizations are configurable.</Item>
            <Item>Issue or redeem Robinhood Stock Tokens. The token issuer (RHJ) controls that, entirely off-chain of WoolFi.</Item>
            <Item>Waive the oracle staleness and sanity checks. Those are hard-coded in the adapters.</Item>
            <Item>Receive URU taken in a drawdown. Drawn-down URU goes to a separate rebalancer address, never the multisig or the timelock.</Item>
            <Item>Skip the 3-day delay. The timelock has no admin, so even its own rules can only change through the same public queue.</Item>
            <Item>Vote &quot;on your behalf&quot; using URU. Underwriting stake is not voting stake.</Item>
          </List>
        </Group>

        <Group>
          <Q>Is there a delay before settings change?</Q>
          <A>
            Yes. Every settings change waits 3 days in public. A timelock (a contract that holds
            changes in a public queue before they can run) owns the governor, the position
            manager, the rebate distributor, and the zapper. The multisig can only queue a change,
            wait at least 3 days, then run it, so anyone watching the queue sees oracle changes,
            fee changes, vault wiring, break resolution, and unpausing days before they take effect.
            The multisig can also cancel a queued change before it runs. Unstaking URU takes 2
            days, less than the 3-day delay, so a staker who dislikes a queued change can always
            leave before it runs.
          </A>
        </Group>

        <Group>
          <Q>What happens in an emergency?</Q>
          <A>
            Emergency pause is instant. The multisig holds a separate guardian role that can pause
            the hook immediately, stopping swaps and new deposits, and can do nothing else.
            Unpausing waits 3 days through the timelock, so a pause cannot be used to slip a
            change through. Withdrawing liquidity stays open while the hook is paused.
          </A>
        </Group>

        <Group>
          <Q>Who handles structural breaks?</Q>
          <A>
            Nobody needs permission. Detecting a break, confirming it after the waiting period,
            and unlocking a pool once its price has recovered are all open functions anyone can
            call; WoolFi runs a keeper bot that calls them automatically. The waiting period
            itself is public, so stakers and monitors see a break before any URU is drawn down.
            The multisig can also resolve a break, but it is not required.
          </A>
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
            surface that changes often. WoolFi v1 has a fixed 18-pool catalog and an audited
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
  return <section className="slab mt-8 px-6 py-7 sm:px-8">{children}</section>;
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
