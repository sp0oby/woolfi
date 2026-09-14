"use client";

import {useEffect, useState} from "react";
import {createPortal} from "react-dom";

// Tutorial reopens on every visit — user preference. If a "don't show again" UX becomes
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
};

/**
 * Regions are expressed in fixed viewport coordinates that match the TerminalShell layout
 * (header 56px, 3-col grid, ticker ~32px). Approximate; the point is directional attention,
 * not pixel-perfect anchoring.
 */
const STEPS: Step[] = [
  {
    title: "Pick a pool",
    body:
      "The left rail lists all 16 pools. Green dot means live, gray means pending. Use the search or the category chips to filter.",
    region: {top: "56px", left: "0", width: "320px", bottom: "32px"},
    cardPos: "right",
  },
  {
    title: "Read the drift",
    body:
      "The header shows the pair, current state, fair price, live drift in bps, and the tolerance and hard-threshold rails. Green drift is below fair, red is above.",
    region: {top: "56px", left: "320px", right: "480px", height: "84px"},
    cardPos: "center-bottom",
  },
  {
    title: "Watch pool activity",
    body:
      "Drift over time relative to the tolerance band (soft) and hard-threshold rails (amber). Below it, recent swaps classified corrective or adversarial based on whether they reduced drift.",
    region: {top: "140px", left: "320px", right: "480px", bottom: "32px"},
    cardPos: "left",
  },
  {
    title: "Trade, provide, stake, claim",
    body:
      "Right rail tabs. Trade swaps through the router. Liquidity has a Balanced form or a Zap that turns one token into a 50/50 LP. Stake deposits URU into the pool vault. Rebate claims funded Urufu Gemu NFT rebates.",
    region: {top: "56px", right: "0", width: "480px", height: "440px"},
    cardPos: "left",
  },
  {
    title: "Track your position",
    body:
      "Wallet balances, LP shares, staked URU, and pending fees or rewards for the selected pool. Updates as your wallet does.",
    region: {top: "496px", right: "0", width: "480px", bottom: "32px"},
    cardPos: "left",
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
