"use client";

import {useEffect, useState} from "react";
import {createPortal} from "react-dom";

import {openActionTab} from "../poolState";

// Tutorial reopens on every visit (user preference). If a "don't show again" UX becomes
// desirable later, add a checkbox in the tour card and write this key back.
const STORAGE_KEY = "";

type Region = {
  top: string;
  bottom?: string;
  left?: string;
  right?: string;
  width?: string;
  height?: string;
};

type Step = {
  title: string;
  body: string;
  region: Region;
  cardPos: "left" | "right" | "center-top" | "center-bottom";
  /** Right-rail tab to open while this step is showing. */
  tab?: "trade" | "provide" | "stake" | "rebate";
};

/**
 * Regions are expressed in fixed viewport coordinates that match the TerminalShell layout
 * (header 56px, 3-col grid, ticker ~32px). Approximate; the point is directional attention,
 * not pixel-perfect anchoring.
 */
const RAIL: Region = {top: "56px", right: "0", width: "480px", height: "440px"};
const HEADER: Region = {top: "56px", left: "320px", right: "480px", height: "84px"};

const STEPS: Step[] = [
  {
    title: "Connect and approve",
    body:
      "Click Connect in the top right. The first time you trade or deposit a token, you'll sign one extra Approve transaction so WoolFi can move it. That's once per token.",
    region: {top: "0", right: "0", width: "420px", height: "56px"},
    cardPos: "left",
  },
  {
    title: "Pick a pool",
    body:
      "The left rail lists all 18 pools, seeded pools first. A \"needs LP\" tag means the pool is live but empty: nobody can trade it until someone adds liquidity, and that someone can be you. Use the search or the category chips to filter.",
    region: {top: "56px", left: "0", width: "320px", bottom: "32px"},
    cardPos: "right",
  },
  {
    title: "Read the drift",
    body:
      "Drift is how far the pool price sits from the Chainlink price, in basis points (1 bp = 0.01%). Trades that pull drift back toward zero pay a lower fee; trades that push it further away pay more.",
    region: HEADER,
    cardPos: "center-bottom",
  },
  {
    title: "Check the pool state",
    body:
      "The pill next to the pair tells you what you can do right now. Live: trade normally. Needs liquidity: add liquidity first. Break detected: the price ran past the hard threshold, so only trades that fix it are allowed while a waiting period runs. Break confirmed: still broken after the wait, so URU stakers absorb a share. Once the price is back in band the pool unlocks on its own. Hover the pill for details.",
    region: HEADER,
    cardPos: "center-bottom",
  },
  {
    title: "Watch pool activity",
    body:
      "The chart shows drift over time against the tolerance band and the hard threshold. Below it, recent swaps are tagged corrective or adversarial, depending on whether they reduced drift.",
    region: {top: "140px", left: "320px", right: "480px", bottom: "32px"},
    cardPos: "left",
  },
  {
    title: "Trade",
    body:
      "Pick the token you pay with, enter an amount, and swap. The preview shows your fee before you sign. A single trade that would push the price more than 15% from Chainlink is rejected, so try a smaller amount. Holding an Urufu Gemu NFT? A rebate is recorded on every swap automatically.",
    region: RAIL,
    cardPos: "left",
    tab: "trade",
  },
  {
    title: "Add liquidity, three ways",
    body:
      "Balanced: deposit both tokens at the pool ratio. Zap: deposit just one token (or ETH) and WoolFi swaps half for you, so you get LP shares in one transaction. Migrate v3: already an LP on Uniswap v3? Pick your position and it moves here in one transaction, fees included, with leftovers refunded.",
    region: RAIL,
    cardPos: "left",
    tab: "provide",
  },
  {
    title: "First into an empty pool",
    body:
      "An empty pool cannot follow Chainlink on its own, so its price can go stale. If it has, the Liquidity tab shows Sync to Chainlink price above the deposit form. Click it once (gas only, no tokens move), then deposit any of the three ways. Your deposit sets a fair starting ratio, and you earn all the LP fees until others join.",
    region: RAIL,
    cardPos: "left",
    tab: "provide",
  },
  {
    title: "Stake and claim",
    body:
      "Stake deposits URU into this pool's vault: you earn a cut of its swap fees, and in return a confirmed break can draw down part of the vault. Unstaking has a cooldown. Rebate is where Urufu Gemu holders claim back 15% of the fee they actually paid, capped at the base fee.",
    region: RAIL,
    cardPos: "left",
    tab: "stake",
  },
  {
    title: "Track your position",
    body:
      "Wallet balances, LP shares, staked URU, and pending fees or rewards for the selected pool. Updates as your wallet does. Reopen this tour anytime with How to use. Unfamiliar term? See the glossary in /docs.",
    region: {top: "496px", right: "0", width: "480px", bottom: "32px"},
    cardPos: "left",
    tab: "trade",
  },
];

export function TerminalTour() {
  const [mounted, setMounted] = useState(false);
  const [open, setOpen] = useState(false);
  const [index, setIndex] = useState(0);

  useEffect(() => {
    setMounted(true);
    // `?tour=1` in the URL forces the tour open (useful for demos / screenshots).
    const forced =
      typeof window !== "undefined" && new URLSearchParams(window.location.search).has("tour");
    if (forced) {
      setOpen(true);
      return;
    }
    let disclosureAcked = false;
    try {
      disclosureAcked = !!window.localStorage.getItem("woolfi.disclosure.ack.v3");
    } catch {
      setOpen(true);
      return;
    }
    // Open every visit. Wait for disclosure ack if it's about to show.
    if (disclosureAcked) {
      const t = window.setTimeout(() => setOpen(true), 600);
      return () => window.clearTimeout(t);
    }
    function onDisclosureAcked() {
      setOpen(true);
    }
    window.addEventListener("woolfi:disclosure-acked", onDisclosureAcked as EventListener);
    return () =>
      window.removeEventListener("woolfi:disclosure-acked", onDisclosureAcked as EventListener);
  }, []);

  useEffect(() => {
    function onOpen() {
      setIndex(0);
      setOpen(true);
    }
    window.addEventListener("woolfi:open-tour", onOpen as EventListener);
    return () => window.removeEventListener("woolfi:open-tour", onOpen as EventListener);
  }, []);

  // Show the tab each how-to step is talking about.
  useEffect(() => {
    const tab = open ? STEPS[index]?.tab : undefined;
    if (tab) openActionTab(tab);
  }, [open, index]);

  function finish() {
    setOpen(false);
  }

  if (!mounted || !open) return null;

  const step = STEPS[index];
  const last = index === STEPS.length - 1;

  return createPortal(
    <div className="fixed inset-0 z-50">
      {/* Dim the whole screen */}
      <div className="absolute inset-0 bg-black/70" onClick={() => finish()} />

      {/* Spotlight cutout */}
      <div
        className="pointer-events-none absolute border border-signal shadow-[0_0_0_9999px_rgba(0,0,0,0.55)]"
        style={{
          top: step.region.top,
          left: step.region.left,
          right: step.region.right,
          bottom: step.region.bottom,
          width: step.region.width,
          height: step.region.height,
        }}
      />

      {/* Instruction card */}
      <div
        className="absolute w-[360px] border border-line-strong bg-panel p-5 shadow-xl"
        style={cardPosition(step)}
      >
        <div className="flex items-baseline justify-between">
          <span className="font-mono text-micro uppercase tracking-[0.24em] text-warn">
            How to use woolfi
          </span>
          <span className="tabular font-mono text-micro text-subtle">
            {index + 1} / {STEPS.length}
          </span>
        </div>

        <h3 className="mt-3 font-display text-[22px] font-medium leading-tight text-ink">
          {step.title}
        </h3>
        <p className="mt-3 text-[13px] leading-relaxed text-ink/80">{step.body}</p>

        <div className="mt-5 flex items-center justify-between">
          <button
            type="button"
            onClick={finish}
            className="font-mono text-micro uppercase tracking-[0.22em] text-muted hover:text-ink"
          >
            Skip tour
          </button>
          <div className="flex items-center gap-2">
            {index > 0 ? (
              <button
                type="button"
                onClick={() => setIndex((i) => i - 1)}
                className="border border-line bg-surface px-3 py-1.5 font-mono text-micro uppercase tracking-[0.22em] text-ink hover:border-line-strong"
              >
                Back
              </button>
            ) : null}
            <button
              type="button"
              onClick={() => (last ? finish() : setIndex((i) => i + 1))}
              className="border border-signal bg-signal/10 px-3 py-1.5 font-mono text-micro uppercase tracking-[0.22em] text-signal hover:bg-signal/20"
            >
              {last ? "Got it" : "Next"}
            </button>
          </div>
        </div>

        {/* Step dots */}
        <div className="mt-4 flex justify-center gap-1.5">
          {STEPS.map((_, i) => (
            <button
              key={i}
              type="button"
              onClick={() => setIndex(i)}
              aria-label={`Go to step ${i + 1}`}
              className={`h-1.5 w-4 transition-colors ${
                i === index ? "bg-signal" : "bg-line hover:bg-line-strong"
              }`}
            />
          ))}
        </div>
      </div>
    </div>,
    document.body,
  );
}

/** Small "?" button that reopens the tour. Lives in the terminal header. */
export function TerminalTourButton() {
  function open() {
    window.dispatchEvent(new CustomEvent("woolfi:open-tour"));
  }
  return (
    <button
      type="button"
      onClick={open}
      className="inline-flex items-center gap-1.5 border border-line bg-surface px-2.5 py-1 font-mono text-micro uppercase tracking-[0.22em] text-muted transition-colors hover:border-signal hover:text-signal"
      title="Open the how-to-use tour"
    >
      <span className="tabular">?</span>
      <span>How to use</span>
    </button>
  );
}

function cardPosition(step: Step): React.CSSProperties {
  const gutter = 24;
  switch (step.cardPos) {
    case "right":
      return {top: 96, left: `calc(${step.region.left ?? "0px"} + ${step.region.width ?? "0px"} + ${gutter}px)`};
    case "left":
      return {top: 96, right: `calc(${step.region.right ?? "0px"} + ${step.region.width ?? "0px"} + ${gutter}px)`};
    case "center-top":
      return {top: 96, left: "50%", transform: "translateX(-50%)"};
    case "center-bottom":
      return {bottom: 80, left: "50%", transform: "translateX(-50%)"};
  }
}
