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
  {id: "launch-liquidity", label: "Launch liquidity"},
  {id: "using", label: "Using WoolFi"},
  {id: "lp-vs-underwriter", label: "LPs vs underwriters"},
  {id: "rebates", label: "Urufu Gemu rebates"},
  {id: "hours", label: "Market hours"},
  {id: "rht", label: "Robinhood Stock Tokens"},
  {id: "breaks", label: "Structural breaks"},
  {id: "migrate", label: "Migrate from Uniswap v3"},
  {id: "arb-agent", label: "Arbitrage agent"},
  {id: "glossary", label: "Glossary"},
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
              The catalog spans stock/USDG, stock/WETH, stock/stock spread, and crypto pools. One
              hook contract serves all 18; each pool has its own oracles, risk settings, and URU
              vault. Before launch every pool shows as{" "}
              <span className="text-muted">pre-launch</span> and actions stay disabled. At launch
              all 18 go <span className="text-pos">live</span> together.
            </p>
          </Section>

          <Section id="launch-liquidity" label="Launch liquidity">
            <p>
              All 18 pools go live together at launch. WETH/USDG and NVDA/USDG are seeded at
              launch; the rest are open for the first liquidity providers, including one-click
              migration from Uniswap v3.
            </p>
            <p>
              Every pool is initialized at a launch price taken from Chainlink, so the first LP
              deposits at a fair ratio rather than setting the price. A pool with no deposits yet
              shows a <span className="text-warn">needs liquidity</span> tag: there is nothing to
              trade against until someone adds liquidity, Zaps in one token, or migrates a v3
              position. The terminal lists seeded pools first.
            </p>
            <p>
              An empty pool has nothing to trade against, so its price stays put while Chainlink
              moves. The keeper re-syncs every empty pool to the Chainlink price on each run, and
              anyone can do the same from the Liquidity tab with Sync to Chainlink price: one
              transaction, gas only, no tokens move. That keeps the first deposit at a fair ratio and
              stops a stale empty pool from tripping a false structural break.
            </p>
          </Section>

          <Section id="using" label="Using WoolFi">
            <p>
              Connect a Robinhood Chain wallet, select a live pool, approve the token you want to
              spend, and swap. The hook chooses the fee from the trade&apos;s direction and oracle
              drift; the router enforces your minimum output. A single trade that would push the price
              more than the hard threshold from Chainlink is rejected; try a smaller amount. Urufu
              Gemu holders then claim funded rebates from the Rebate tab. Users who want fee income can instead add both
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
              earns back 15% of the fee it actually paid, capped at the base fee, in the input
              token. A corrective trade that paid a discounted fee gets 15% of that discounted
              fee; surcharges above the base fee are not rebated. Multiple NFTs do not stack the
              benefit, and the weekly cap is per wallet. Rebates are funded in advance and
              claimed from the terminal.
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
              If the pool price drifts more than the hard threshold (default 15%) from the
              Chainlink price, the pool enters a structural break. It happens in two steps so a
              brief spike cannot cost URU stakers anything:
            </p>
            <ol className="mt-4 space-y-2 border-l border-line pl-5">
              <li>
                <span className="text-ink">Detected.</span> The hook caches the fair price, admits
                only corrective swaps, and blocks new deposits. Nothing is drawn from the vault.
                The terminal shows <span className="text-warn">Break detected: confirming</span>{" "}
                with a countdown, or <em>waiting for market open</em> when the market is closed.
              </li>
              <li>
                <span className="text-ink">Confirmed.</span> After the waiting period (default
                1 hour of open-market time, never during the opening stabilization window), anyone
                can call confirm. If the price is still past the threshold, the URU vault is drawn
                down once, capped at the pool&apos;s drawdown share, to fund the rebalance. If it
                has recovered, the break simply clears and nothing is taken.
              </li>
              <li>
                <span className="text-ink">Recovered.</span> Once a confirmed pool is back inside
                its tolerance band, anyone can unlock it. The keeper bot does both calls
                automatically; governance can also resolve a break directly.
              </li>
            </ol>
            <p className="mt-4">
              Withdrawals stay open in every state. Separately, every swap in every state is
              checked: a single trade that would push an in-range pool past the hard threshold
              is rejected outright.
            </p>
          </Section>

          <Section id="migrate" label="Migrate from Uniswap v3">
            <p>
              Already providing liquidity for one of these pairs on Uniswap v3? The Liquidity tab
              has a <span className="text-ink">Migrate v3</span> mode. Pick your position and
              WoolFi&apos;s migrator withdraws it, collects its accrued fees, and deposits
              everything full-range into the matching WoolFi pool in one transaction. Anything
              the full-range ratio cannot use is refunded to you, and the empty v3 NFT stays in
              your wallet. You approve the migrator for that one NFT first.
            </p>
            <p>
              Migration follows the same rules as a normal deposit: the pool must be in band, not
              in a break, and (for stock pools) the market must be open. Migrating into an empty
              pool whose price has drifted? Use Sync to Chainlink price first.
            </p>
          </Section>

          <Section id="arb-agent" label="Arbitrage agent">
            <p>
              The repo ships an open-source arbitrage agent that keeps WoolFi pools close to the
              price on Uniswap v3 without needing its own capital. It borrows inside a single v4
              transaction, trades the WoolFi pool toward fair value (paying the discounted
              corrective fee), hedges on Uniswap v3, and repays, keeping the difference. If the
              trade is not profitable the whole transaction reverts.
            </p>
            <p>
              Anyone can run it. An optional AI layer writes plain-English summaries of each
              opportunity; it never decides trades.{" "}
              <a
                href="https://github.com/sp0oby/woolfi/tree/main/arb-agent"
                target="_blank"
                rel="noreferrer"
                className="text-ink underline underline-offset-4 hover:text-signal"
              >
                Source and setup ↗
              </a>
            </p>
          </Section>

          <Section id="glossary" label="Glossary">
            <dl className="border border-line bg-panel">
              <Term name="Drift">
                How far the pool price sits from the Chainlink price, measured in basis points.
              </Term>
              <Term name="Fair value">
                The price implied by the two Chainlink feeds for the pair; the target the hook
                pulls the pool toward.
              </Term>
              <Term name="Corrective / Adversarial">
                A swap that moves the pool toward fair value is corrective and pays a lower fee;
                one that moves it away is adversarial and pays a higher fee.
              </Term>
              <Term name="Tolerance band">
                The drift range (default 500 bps either side) inside which the pool charges only
                the flat base fee.
              </Term>
              <Term name="Hard threshold">
                The drift level (default 1500 bps) at which the hook declares a structural break.
              </Term>
              <Term name="Structural break">
                The contained state after a hard-threshold crossing: fair price is cached, only
                corrective swaps are admitted, new deposits are blocked, withdrawals stay open.
                It is detected first and confirmed later; see Structural breaks above.
              </Term>
              <Term name="Break confirmation">
                The second step of a break. After a waiting period of open-market time, anyone can
                confirm; the URU vault is drawn down only if the price is still past the threshold.
              </Term>
              <Term name="Break guard">
                A per-swap check: a single trade that would push the pool more than the hard
                threshold from Chainlink is rejected.
              </Term>
              <Term name="Unseeded pool">
                A live pool that nobody has deposited into yet. It opens at the Chainlink launch
                price and waits for its first liquidity provider.
              </Term>
              <Term name="Price sync">
                Moving an empty pool to the current Chainlink price with the pool aligner. With no
                liquidity there is nothing to trade against, so it costs only gas. The keeper does it
                automatically; the Liquidity tab offers it before a first deposit.
              </Term>
              <Term name="Migration">
                Moving a Uniswap v3 position into a WoolFi pool in one transaction with the v3
                migrator.
              </Term>
              <Term name="Stabilization">
                A short window after the referenced market opens during which asymmetric fees stay
                off so the first prints can settle.
              </Term>
              <Term name="bps">
                Basis points. 1 bp = 0.01%, so 100 bps = 1%.
              </Term>
              <Term name="URU">
                An external token, bought elsewhere, that is staked into per-pool vaults as
                underwriting capital. It carries no WoolFi governance rights.
              </Term>
              <Term name="Underwriting">
                Staking URU to backstop a pool in exchange for a share of its swap fees, while
                accepting drawdown risk if the pool breaks.
              </Term>
              <Term name="Drawdown">
                The portion of a pool&apos;s URU vault (default 20%) used to fund a rebalance when a
                structural break is confirmed. It happens at most once per break.
              </Term>
              <Term name="Urufu Gemu">
                An NFT collection. Holding one earns the wallet 15% of the fee it actually paid on
                each swap, capped at the base fee, funded in advance and capped weekly per wallet.
              </Term>
              <Term name="Zap">
                Depositing a single token; the zapper swaps half of it through an approved
                executor so you end up with both pool tokens and LP shares in one transaction.
              </Term>
            </dl>
          </Section>

          <Section id="status" label="Status">
            <div className="border border-line bg-panel">
              <StatusRow label="Network" value="Robinhood Chain · 4663" />
              <StatusRow label="Architecture" value="Uniswap v4 multi-pool hook" />
              <StatusRow label="Catalog" value="18 pools · all live at launch" />
              <StatusRow label="Seeded at launch" value="WETH/USDG · NVDA/USDG" />
              <StatusRow label="Breaks" value="Two-step · detect, then confirm" />
              <StatusRow label="Migration" value="Uniswap v3 → WoolFi, one tx" />
              <StatusRow label="Empty pools" value="Synced to Chainlink by the keeper" />
              <StatusRow label="Underwriting" value="URU · per-pool vault" />
              <StatusRow label="Oracle" value="Chainlink Data Feeds" />
              <StatusRow label="Contracts" value="Not deployed yet" />
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
              <SourceLink
                href="https://github.com/sp0oby/woolfi/tree/main/arb-agent"
                label="arb-agent"
                hint="zero-capital arbitrage bot"
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

function Term({name, children}: {name: string; children: React.ReactNode}) {
  return (
    <div className="border-b border-line px-4 py-3 last:border-b-0">
      <dt className="font-mono text-2xs uppercase tracking-[0.22em] text-signal">{name}</dt>
      <dd className="mt-1.5 text-[14px] leading-[1.6] text-ink/80">{children}</dd>
    </div>
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
