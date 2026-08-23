import Link from "next/link";

import {Header} from "@/components/Header";
import {Footer} from "@/components/Footer";
import {LivePoolStrip} from "@/components/LivePoolStrip";

export default function SplashPage() {
  return (
    <main className="min-h-screen">
      <Header />
      <article className="mx-auto max-w-2xl px-6 pt-24">
        <h1 className="text-[44px] sm:text-5xl font-medium tracking-[-0.02em] leading-[1.05]">
          A market for the spread.
        </h1>
        <p className="mt-8 text-[17px] leading-relaxed text-ink/85">
          WoolFi is a multi-pool market for Robinhood Stock Tokens on Robinhood Chain. Each
          Uniswap v4 pool trades the relationship between a stock token and{" "}
          <span className="font-mono text-white">USDG</span> or{" "}
          <span className="font-mono text-white">WETH</span>.
        </p>

        <Section label="Mechanic">
          Each WoolFi pool enforces dollar-neutrality between its two reserves. The hook intercepts
          every swap and applies an asymmetric fee based on which direction the swap pushes the pool.
          Swaps toward the oracle-implied fair price are discounted; swaps away are surcharged. The
          spread mean-reverts. Liquidity providers capture the elevated fees from the directional
          flow.
        </Section>

        <Section label="Pool catalog">
          Browse stock/USDG, stock/WETH, stock/stock spread, and crypto pools. The catalog shows
          both live and pending pools; pending pools remain disabled until their verified oracles
          and production deployments are ready.
        </Section>

        <Section label="Market hours">
          Hours are configured per pool. Stock-token pools follow their underlying market schedule
          and use flat fees while that market is closed. The pool stays usable, but does not promise
          convergence in those windows. <span className="font-mono text-white">WETH/USDG</span> is
          always open. Per-pool vaults use URU as the underwriting asset for structural breaks.
        </Section>

        <Section label="Catalog status">
          <p className="mt-3 text-[15px] leading-[1.75] text-ink/85">
            Pools are listed as pending or live on Robinhood Chain. For live pools, drift, fair
            price, and vault stake are read directly from deployed contracts.
          </p>
          <LivePoolStrip />
        </Section>

        <Section label="Stock-token disclosure">
          Robinhood Stock Tokens issued by Robinhood Assets (Jersey) Limited (RHJ) provide economic
          exposure to referenced securities but not ownership of those securities. Issuer terms and
          geographic restrictions apply; confirm eligibility before holding or trading a token.
        </Section>

        <Section label="Open">
          <div className="mt-4 flex flex-col sm:flex-row gap-3 sm:gap-6 items-stretch sm:items-baseline">
            <Link
              href="/app"
              className="inline-flex items-center justify-center border border-line px-6 py-3 font-mono text-[12px] uppercase tracking-[0.22em] text-white hover:bg-white/5 transition-colors"
            >
              Open the dashboard →
            </Link>
            <Link
              href="/docs"
              className="inline-flex items-center justify-center px-2 py-3 font-mono text-[12px] uppercase tracking-[0.22em] text-muted hover:text-white transition-colors"
            >
              Read the docs
            </Link>
          </div>
        </Section>
      </article>
      <Footer />
    </main>
  );
}

function Section({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <section className="mt-20">
      <h2 className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">{label}</h2>
      <div className="mt-4 text-[15px] leading-[1.75] text-ink/85">{children}</div>
    </section>
  );
}
