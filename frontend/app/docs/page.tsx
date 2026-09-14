import type {Metadata} from "next";
import Link from "next/link";

import {DeploymentPanel} from "@/components/DeploymentPanel";
import {Footer} from "@/components/Footer";
import {Header} from "@/components/Header";

export const metadata: Metadata = {
  title: "Docs",
  description:
    "How WoolFi's Robinhood Chain multi-pool market, market hours, and URU underwriting work.",
};

const SECTIONS = [
  {id: "hook", label: "The hook"},
  {id: "pools", label: "Pools"},
  {id: "using", label: "Using WoolFi"},
  {id: "lp-vs-underwriter", label: "LPs vs underwriters"},
  {id: "rebates", label: "Urufu Gemu rebates"},
  {id: "hours", label: "Market hours"},
  {id: "rht", label: "Robinhood Stock Tokens"},
  {id: "breaks", label: "Structural breaks"},
  {id: "status", label: "Status"},
  {id: "source", label: "Source"},
] as const;

export default function DocsPage() {
  return (
    <main className="flex min-h-screen flex-col bg-bg">
      <Header />

      <div className="mx-auto flex w-full max-w-7xl gap-8 px-6 pt-12 pb-24 lg:pt-16">
        <TocRail />
        <article className="min-w-0 flex-1 max-w-3xl">
          <p className="font-mono text-2xs uppercase tracking-[0.28em] text-signal">Docs</p>
          <h1 className="mt-4 font-display text-[52px] font-medium leading-[1.02] tracking-tight text-ink sm:text-[64px]">
            How woolfi works.
          </h1>
          <p className="mt-8 text-[17px] leading-relaxed text-ink/85">
            WoolFi is a Uniswap v4 multi-pool market on Robinhood Chain. Each pool uses
            oracle-aware fees to trade the economic relationship between two long-only tokens.
          </p>

          <Section id="hook" label="The hook">
            <p>
              Every swap routes through the hook&apos;s{" "}
              <code className="font-mono text-ink">beforeSwap</code> callback. The hook reads two
              oracle prices and the pool&apos;s current ratio, computes the implied drift from
              fair value, and returns an asymmetric fee. Swaps that move the pool <em>toward</em>{" "}
              fair are discounted below the base fee; swaps that move it away are surcharged.
              The result is a market force that pulls the pool back to the implied equilibrium
              without LPs or stakers having to actively manage anything.
            </p>
          </Section>

          <Section id="pools" label="Pools">
            <p>
              The catalog spans stock/USDG, stock/WETH, stock/stock spread, and crypto pools. A
              pool is marked <span className="text-warn">pending</span> until its verified oracles
              and production contracts are ready, then marked <span className="text-pos">live</span>.
              Actions stay disabled for pending pools.
            </p>
          </Section>

          <Section id="using" label="Using WoolFi">
            <p>
              Connect a Robinhood Chain wallet, select a live pool, approve the token you want to
              spend, and swap. The hook chooses the fee from the trade&apos;s direction and oracle
              drift; the router enforces your minimum output. Urufu Gemu holders then claim funded
              base-fee rebates from the Rebate tab. Users who want fee income can instead add both
              pool assets as liquidity or stake URU as risk-bearing underwriting.
            </p>
          </Section>

          <Section id="lp-vs-underwriter" label="LPs vs underwriters">
            <p>
              <span className="text-ink">Liquidity providers</span> deposit token0 and token1,
              mint non-transferable LP shares against a WoolFiPositionManager, and collect a
              share of swap fees in both tokens. They do <em>not</em> bear structural-break risk.
            </p>
            <p>
              <span className="text-ink">URU underwriters</span> deposit URU into a per-pool
              vault. They may earn a configured cut of swap fees in the pool assets, but bear
              structural-break risk: a vault drawdown can fund a rebalance and reduce vault
              positions pro rata. URU is the underwriting asset; it is not presented as a
              governance voting token.
            </p>
          </Section>

          <Section id="rebates" label="Urufu Gemu rebates">
            <p>
              A wallet holding at least one verified Urufu Gemu NFT when its router swap settles
              earns 15% of the pool&apos;s base-fee portion back in the input token. Directional
              surcharges are excluded, multiple NFTs do not stack the benefit, and per-token
              weekly caps apply. Rebates are funded in advance and claimed from the terminal.
            </p>
          </Section>

          <Section id="hours" label="Market hours">
            <p>
              Hours are configured per pool. When a stock token&apos;s underlying market is
              closed, WoolFi cannot promise that the spread will converge, so the pool changes
              behavior:
            </p>
            <ul className="mt-4 space-y-2 border-l border-line pl-5">
              <li>
                <span className="text-ink">Swaps stay open</span>, at a flat symmetric fee. The
                asymmetric mechanic is paused until reopen.
              </li>
              <li>
                <span className="text-ink">Deposits are blocked.</span> The in-band check may
                rely on a stale underlying-market quote while directional fees are paused.
              </li>
              <li>
                <span className="text-ink">Withdrawals stay open</span> the entire time. Existing
                LPs already committed with a defined risk profile.
              </li>
              <li>
                <span className="text-ink">Structural-break detection is paused.</span> The
                hard-threshold drawdown only runs when prices are live.
              </li>
            </ul>
            <p className="mt-4">
              Each stock-token pool resumes its active-market behavior according to its
              configured schedule. <code className="font-mono text-ink">WETH/USDG</code> is
              always open.
            </p>
          </Section>

          <Section id="rht" label="Robinhood Stock Tokens">
            <p>
              Robinhood Stock Tokens are issued by Robinhood Assets (Jersey) Limited (RHJ). They
              provide economic exposure to referenced securities but not ownership, voting
              rights, or other shareholder rights. Issuer terms and geographic restrictions
              apply. WoolFi does not determine eligibility; users must confirm they may hold and
              trade each token.
            </p>
          </Section>

          <Section id="breaks" label="Structural breaks">
            <p>
              If the oracle disagrees with the pool by more than a hard threshold (default 15%),
              the hook caches that fair price, admits only corrective swaps against it, and
              blocks new deposits. A capped URU vault drawdown can fund the rebalance. Withdrawals
              stay open.
            </p>
          </Section>

          <Section id="status" label="Status">
            <div className="border border-line bg-panel">
              <StatusRow label="Network" value="Robinhood Chain · 4663" />
              <StatusRow label="Architecture" value="Uniswap v4 multi-pool hook" />
              <StatusRow label="Catalog" value="16 pools · coordinated launch" />
              <StatusRow label="Underwriting" value="URU · per-pool vault" />
              <StatusRow label="Oracle" value="Chainlink Data Feeds" />
              <StatusRow label="Audit" value="Pending" />
            </div>
          </Section>

          <Section id="source" label="Source">
            <ul className="space-y-3">
              <SourceLink
                href="https://github.com/sp0oby/woolfi/blob/main/PROJECT_SPEC.md"
                label="PROJECT_SPEC.md"
                hint="canonical specification"
              />
              <SourceLink
                href="https://github.com/sp0oby/woolfi"
                label="Source on GitHub"
                hint="contracts + tests"
              />
            </ul>
          </Section>

          <DeploymentPanel />

          <div className="mt-16 flex flex-wrap gap-3">
            <Link
              href="/app"
              className="inline-flex items-center gap-2 border border-signal bg-signal/10 px-5 py-3 font-mono text-2xs uppercase tracking-[0.24em] text-signal transition-colors hover:bg-signal/20"
            >
              Open the terminal →
            </Link>
            <Link
              href="/governance"
              className="inline-flex items-center gap-2 border border-line bg-panel px-5 py-3 font-mono text-2xs uppercase tracking-[0.24em] text-ink transition-colors hover:border-line-strong"
            >
              Who decides what
            </Link>
          </div>
        </article>
      </div>

      <Footer />
    </main>
  );
}

function TocRail() {
  return (
    <aside className="sticky top-4 hidden h-max w-56 shrink-0 border border-line bg-panel lg:block">
      <div className="border-b border-line px-4 py-2.5">
        <span className="font-mono text-2xs uppercase tracking-[0.24em] text-muted">Contents</span>
      </div>
      <nav>
        {SECTIONS.map((s) => (
          <a
            key={s.id}
            href={`#${s.id}`}
            className="block border-l-2 border-transparent px-4 py-1.5 font-mono text-2xs uppercase tracking-[0.18em] text-muted transition-colors hover:border-signal hover:bg-white/[0.02] hover:text-ink"
          >
            {s.label}
          </a>
        ))}
      </nav>
    </aside>
  );
}

function Section({id, label, children}: {id: string; label: string; children: React.ReactNode}) {
  return (
    <section id={id} className="mt-14 scroll-mt-20">
      <p className="font-mono text-2xs uppercase tracking-[0.24em] text-signal">{label}</p>
      <div className="mt-4 space-y-4 text-[15px] leading-[1.7] text-ink/85">{children}</div>
    </section>
  );
}

function StatusRow({label, value}: {label: string; value: string}) {
  return (
    <div className="flex items-baseline justify-between border-b border-line px-4 py-2.5 last:border-b-0">
      <span className="font-mono text-2xs uppercase tracking-[0.22em] text-muted">{label}</span>
      <span className="tabular font-mono text-2xs text-ink">{value}</span>
    </div>
  );
}

function SourceLink({href, label, hint}: {href: string; label: string; hint: string}) {
  return (
    <li>
      <a
        href={href}
        target="_blank"
        rel="noreferrer"
        className="group flex items-baseline gap-3 border border-line bg-panel px-4 py-3 font-mono text-2xs text-ink transition-colors hover:border-line-strong hover:bg-surface"
      >
        <span className="underline-offset-4 group-hover:underline">{label}</span>
        <span className="text-subtle">·</span>
        <span className="uppercase tracking-[0.18em] text-muted">{hint}</span>
        <span className="ml-auto text-subtle">↗</span>
      </a>
    </li>
  );
}
