import Link from "next/link";

import {Footer} from "@/components/Footer";
import {Header} from "@/components/Header";
import {TerminalTicker} from "@/components/terminal/TerminalTicker";
import {HeroFiber} from "@/components/wool/HeroFiber";
import {Motion} from "@/components/wool/Motion";
import {Seam} from "@/components/wool/Seam";
import {StitchedWordmark} from "@/components/wool/StitchedWordmark";
import {ThreadCanvas} from "@/components/wool/ThreadCanvas";

export default function SplashPage() {
  return (
    <main className="flex min-h-screen flex-col bg-bg">
      <Header />

      <Motion />
      <section className="relative isolate flex flex-1 flex-col items-center justify-center overflow-hidden px-6 py-24 text-center">
        <HeroFiber />
        <p className="font-mono text-2xs uppercase tracking-[0.32em] text-signal">
          A market for the spread · Robinhood Chain
        </p>

        <StitchedWordmark />

        <p className="mt-10 max-w-2xl text-[19px] leading-relaxed text-ink/90 sm:text-[22px]">
          Trade stock tokens on Robinhood Chain, with fees that reward keeping prices honest.
        </p>
        <p className="mt-3 max-w-xl text-[15px] leading-relaxed text-ink/65 sm:text-[16px]">
          Trades that pull a pool toward the real price cost less. Trades that push it away cost
          more.
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

      <section data-reveal aria-label="How the fee works" className="pb-16">
        <ThreadCanvas className="block h-[200px] w-full sm:h-[240px]" />
        <p className="mx-auto mt-2 max-w-xl px-6 text-center font-mono text-2xs uppercase leading-relaxed tracking-[0.22em] text-muted">
          Two strands: the pool&apos;s price and the real price. The fee keeps pulling them back
          together.
        </p>
      </section>

      <section data-reveal aria-label="Ways to use WoolFi" className="mx-auto mb-24 w-full max-w-4xl px-6">
        <Seam className="mb-10 opacity-70" />
        <ul className="grid gap-10 sm:grid-cols-3 sm:gap-8">
          <Role label="Trade">Swap MSTR, NVDA, SPY and more against USDG or WETH.</Role>
          <Role label="Provide">Add liquidity to a pool and earn its swap fees.</Role>
          <Role label="Underwrite">Stake URU behind a pool to back it and take a cut of its fees.</Role>
        </ul>
      </section>

      <section
        data-reveal
        aria-labelledby="urufu-gemu-heading"
        className="mx-auto mb-20 grid w-full max-w-4xl items-center gap-8 px-6 sm:grid-cols-[220px_1fr] sm:gap-12"
      >
        <figure className="swatch mx-auto w-44 sm:w-full">
          {/* Pixel art: served pre-sized as-is so the optimizer never resamples its edges. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/media/urufu-gemu.webp"
            alt="An Urufu Gemu sheep holding a ball of cream yarn"
            width={512}
            height={512}
            loading="lazy"
            className="pixelated block h-auto w-full"
          />
        </figure>
        <div className="text-center sm:text-left">
          <p className="font-mono text-2xs uppercase tracking-[0.28em] text-signal">Urufu Gemu</p>
          <h2
            id="urufu-gemu-heading"
            className="mt-3 font-display text-[34px] font-medium leading-[1.05] tracking-tight text-ink sm:text-[40px]"
          >
            The flock trades cheaper.
          </h2>
          <p className="mt-4 text-[15px] leading-relaxed text-ink/75">
            Hold at least one Urufu Gemu NFT when a swap settles and 15% of the fee you paid comes
            back to you, capped at the base fee and claimed from the terminal.
          </p>
          <Link
            href="/docs#rebates"
            className="mt-5 inline-flex items-center gap-2 font-mono text-2xs uppercase tracking-[0.24em] text-signal underline-offset-4 hover:underline"
          >
            How rebates work <span aria-hidden>→</span>
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

      <Footer />
      {/* Pinned to the bottom of the screen while scrolling, resting at the page end. */}
      <div className="sticky bottom-0 z-20 mt-auto">
        <TerminalTicker />
      </div>
    </main>
  );
}

function Role({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <li className="text-center sm:text-left">
      <p className="font-mono text-2xs uppercase tracking-[0.24em] text-signal">{label}</p>
      <p className="mt-3 text-[15px] leading-relaxed text-ink/75">{children}</p>
    </li>
  );
}
