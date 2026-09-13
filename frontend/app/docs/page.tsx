import type {Metadata} from "next";
import Link from "next/link";

import {Header} from "@/components/Header";
import {Footer} from "@/components/Footer";
import {DeploymentPanel} from "@/components/DeploymentPanel";

export const metadata: Metadata = {
  title: "Docs",
  description:
    "How WoolFi's Robinhood Chain multi-pool market, market hours, and URU underwriting work.",
};

export default function DocsPage() {
  return (
    <main className="min-h-screen">
      <Header />
      <article className="mx-auto max-w-2xl px-6 pt-24 pb-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">Docs</p>
        <h1 className="mt-3 text-[36px] sm:text-[44px] font-medium tracking-[-0.02em] leading-[1.1]">
          How WoolFi works.
        </h1>
        <p className="mt-8 text-[17px] leading-relaxed text-ink/85">
          WoolFi is a Uniswap v4 multi-pool market on Robinhood Chain. Each pool uses oracle-aware
          fees to trade the economic relationship between two long-only tokens.
        </p>

        <Section label="The hook">
          <p>
            Every swap routes through the hook's <code className="font-mono">beforeSwap</code>{" "}
            callback. The hook reads two oracle prices and the pool's current ratio, computes the
            implied drift from fair value, and returns an asymmetric fee. Swaps that move the pool
            <em> toward</em> fair are discounted below the base fee; swaps that move it away are
            surcharged. The result is a market force that pulls the pool back to the implied
            equilibrium without LPs or stakers having to actively manage anything.
          </p>
        </Section>

        <Section label="Pools">
          <p>
            The catalog spans stock/USDG, stock/WETH, stock/stock spread, and crypto pools. A pool
            is marked <span className="text-white">pending</span> until its verified oracles and
            production contracts are ready, then marked <span className="text-white">live</span>.
            Actions stay disabled for pending pools.
          </p>
        </Section>

        <Section label="Using WoolFi">
          <p>
            Connect a Robinhood Chain wallet, select a live pool, approve the token you want to
            spend, and swap. The hook chooses the fee from the trade&apos;s direction and oracle
            drift; the router enforces your minimum output. Urufu Gemu holders then claim funded
            base-fee rebates from the NFT rebates tab. Users who want fee income can instead add
            both pool assets as liquidity or stake URU as risk-bearing underwriting.
          </p>
        </Section>

        <Section label="LPs vs underwriters">
          <p>
            <span className="text-white">Liquidity providers</span> deposit token0 and token1, mint
            non-transferable LP shares against a WoolFiPositionManager, and collect a share of swap
            fees in both tokens. They do <em>not</em> bear structural-break risk.
          </p>
          <p className="mt-4">
            <span className="text-white">URU underwriters</span> deposit URU into a per-pool vault.
            They may earn a configured cut of swap fees in the pool assets, but bear structural-break
            risk: a vault drawdown can fund a rebalance and reduce vault positions pro rata. URU is
            the underwriting asset; it is not presented as a governance voting token.
          </p>
        </Section>

        <Section label="Urufu Gemu rebates">
          <p>
            A wallet holding at least one verified Urufu Gemu NFT when its router swap settles
            earns 15% of the pool&apos;s base-fee portion back in the input token. Directional
            surcharges are excluded, multiple NFTs do not stack the benefit, and per-token weekly
            caps apply. Rebates are funded in advance and claimed from the dashboard.
          </p>
        </Section>

        <Section id="market-hours" label="Market hours">
          <p>
            Hours are configured per pool. When a stock token's underlying market is closed, WoolFi
            cannot promise that the spread will converge, so the pool changes behavior:
          </p>
          <ul className="space-y-2 text-[14px] leading-relaxed text-ink/85 list-disc pl-5 marker:text-muted">
            <li><span className="text-white">Swaps stay open</span>, at a flat symmetric fee. The asymmetric mechanic is paused until reopen.</li>
            <li><span className="text-white">Deposits are blocked.</span> The in-band check may rely on a stale underlying-market quote while directional fees are paused.</li>
            <li><span className="text-white">Withdrawals stay open</span>, the entire time. Existing LPs already committed with a defined risk profile; letting them out is "you can change your mind."</li>
            <li><span className="text-white">Structural-break detection is paused.</span> The hard-threshold drawdown only runs when prices are live.</li>
          </ul>
          <p>
            Each stock-token pool resumes its active-market behavior according to its configured
            schedule. WETH/USDG is always open.
          </p>
        </Section>

        <Section label="Robinhood Stock Tokens">
          <p>
            Robinhood Stock Tokens are issued by Robinhood Assets (Jersey) Limited (RHJ). They
            provide economic exposure to referenced securities but not ownership, voting rights,
            or other shareholder rights in the underlying securities. Issuer terms and geographic
            restrictions apply. WoolFi does not determine eligibility; users must confirm they may
            hold and trade each token.
          </p>
        </Section>

        <Section label="Structural breaks">
          <p>
            If the oracle disagrees with the pool by more than a hard threshold (default 15%), the
            hook caches that fair price, admits only corrective swaps against it, and blocks new
            deposits. A capped URU vault drawdown can fund the rebalance. Withdrawals stay open.
          </p>
        </Section>

        <Section label="Status">
          <pre className="font-mono text-[13px] leading-[1.8] text-ink/80 border-l border-line pl-5 whitespace-pre">
{`Network            Robinhood Chain
Architecture       Uniswap v4 multi-pool hook
Catalog            Pending and live pools
Underwriting       URU, configured per pool
Audit              Pending`}
          </pre>
        </Section>

        <Section label="Source">
          <ul className="space-y-2 font-mono text-[13px]">
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

        <div className="mt-20">
          <Link
            href="/app"
            className="inline-flex items-center border border-line px-6 py-3 font-mono text-[12px] uppercase tracking-[0.22em] text-white hover:bg-white/5 transition-colors"
          >
            Open the dashboard →
          </Link>
        </div>
      </article>
      <Footer />
    </main>
  );
}

function Section({id, label, children}: {id?: string; label: string; children: React.ReactNode}) {
  return (
    <section id={id} className="mt-16 scroll-mt-20">
      <h2 className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">{label}</h2>
      <div className="mt-4 space-y-4 text-[15px] leading-[1.75] text-ink/85">{children}</div>
    </section>
  );
}

function SourceLink({href, label, hint}: {href: string; label: string; hint: string}) {
  return (
    <li>
      <a
        href={href}
        className="group inline-flex items-baseline gap-3 hover:text-white transition-colors"
      >
        <span className="underline-offset-4 group-hover:underline">{label}</span>
        <span className="text-muted">·</span>
        <span className="text-muted">{hint}</span>
      </a>
    </li>
  );
}
