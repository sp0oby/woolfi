import Link from "next/link";

import {Footer} from "@/components/Footer";
import {Header} from "@/components/Header";
import {TerminalTicker} from "@/components/terminal/TerminalTicker";

export default function SplashPage() {
  return (
    <main className="flex min-h-screen flex-col bg-bg">
      <Header />

      <section className="flex flex-1 flex-col items-center justify-center px-6 py-24 text-center">
        <p className="font-mono text-2xs uppercase tracking-[0.32em] text-signal">
          A market for the spread · Robinhood Chain
        </p>

        <h1 className="mt-8 font-display font-medium leading-[0.9] tracking-tight text-ink text-[120px] sm:text-[180px] lg:text-[220px]">
          woolfi.
        </h1>

        <p className="mt-10 max-w-2xl text-[18px] leading-relaxed text-ink/85 sm:text-[20px]">
          A Uniswap v4 multi-pool market for Robinhood Stock Tokens, WETH, and USDG. Every pool
          trades the <em className="not-italic text-ink">relationship</em> between two assets -
          the hook discounts flow toward oracle-implied fair value and surcharges flow away from
          it.
        </p>

        <p className="mt-6 max-w-xl text-[15px] leading-relaxed text-muted">
          Sixteen pools, coordinated launch, URU underwriting per pool. No rocket emojis.
        </p>

        <div className="mt-12 flex flex-wrap items-center justify-center gap-3">
          <Link
            href="/app"
            className="inline-flex items-center gap-2 border border-signal bg-signal/10 px-6 py-3 font-mono text-2xs uppercase tracking-[0.24em] text-signal transition-colors hover:bg-signal/20"
          >
            Open the terminal
            <span aria-hidden>→</span>
          </Link>
          <Link
            href="/docs"
            className="inline-flex items-center gap-2 border border-line bg-panel px-6 py-3 font-mono text-2xs uppercase tracking-[0.24em] text-ink transition-colors hover:border-line-strong"
          >
            Read the docs
          </Link>
        </div>
      </section>

      <div className="mx-auto w-full max-w-3xl px-6 pb-10">
        <p className="text-center font-mono text-micro leading-relaxed text-subtle">
          Robinhood Stock Tokens are issued by Robinhood Assets (Jersey) Limited (RHJ) and
          provide economic exposure to referenced securities - not ownership, voting rights, or
          other shareholder rights. Issuer terms and geographic restrictions apply. WoolFi is
          pre-launch, unaudited, and provides no investment advice.
        </p>
      </div>

      <TerminalTicker />
      <Footer />
    </main>
  );
}
