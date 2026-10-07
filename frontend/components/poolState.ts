import type {BreakStatus} from "@/hooks/usePool";
import type {CuratedPool} from "@/lib/pools/types";

/** Every user-visible pool state, in the order they take precedence. */
export type PoolStateId =
  | "pre-launch"
  | "needs-liquidity"
  | "break-waiting-open"
  | "break-confirming"
  | "break-confirmed"
  | "stabilizing"
  | "skewed"
  | "closed"
  | "in-band";

export type Tone = "muted" | "pos" | "warn" | "danger";

export type PoolStateView = {
  id: PoolStateId;
  /** Short pill label. */
  label: string;
  tone: Tone;
  /** One plain-English line on what this means for traders, LPs and stakers. */
  meaning: string;
  /** Seconds until a pending break can be confirmed, when known. */
  confirmInSeconds?: number;
};

export function derivePoolState(args: {
  pool: Pick<CuratedPool, "status" | "seeded" | "tradingHours">;
  deployed: boolean;
  breakStatus?: BreakStatus;
  structurallyBroken?: boolean;
  stabilizing?: boolean;
  oracleSkewed?: boolean;
  marketOpen?: boolean;
  /** On-chain LP share supply for the pool. Preferred over the manifest `seeded` flag. */
  totalShares?: bigint;
  nowSeconds?: number;
}): PoolStateView {
  const {pool, deployed, breakStatus, stabilizing, oracleSkewed, marketOpen} = args;
  const now = args.nowSeconds ?? Math.floor(Date.now() / 1000);

  if (!deployed || pool.status !== "live") {
    return {
      id: "pre-launch",
      label: "Pre-launch",
      tone: "muted",
      meaning: "Not deployed yet. All 18 pools open together at launch.",
    };
  }

  if (needsLiquidity(pool, args.totalShares)) {
    return {
      id: "needs-liquidity",
      label: "Needs liquidity",
      tone: "warn",
      meaning:
        "Live, but nobody has deposited yet, so there is nothing to trade against. The first LP sets it in motion: add liquidity, Zap in one token, or migrate a Uniswap v3 position.",
    };
  }

  const broken = breakStatus?.broken ?? args.structurallyBroken ?? false;
  if (broken && breakStatus?.confirmed) {
    return {
      id: "break-confirmed",
      label: "Break confirmed",
      tone: "danger",
      meaning:
        "Only trades that move the price back toward Chainlink are allowed. The URU vault has funded the rebalance. LPs can always withdraw, and the pool unlocks itself once the price is back in range.",
    };
  }
  if (broken && breakStatus?.waitingForMarketOpen) {
    return {
      id: "break-waiting-open",
      label: "Break detected: waiting for market open",
      tone: "warn",
      meaning:
        "The pool is locked to corrective trades. Nothing is taken from URU stakers yet. Confirmation only happens during market hours, after traders have had time to correct the price.",
    };
  }
  if (broken) {
    const readyAt = breakStatus?.confirmReadyAt;
    const confirmInSeconds = readyAt !== undefined ? Math.max(0, readyAt - now) : undefined;
    return {
      id: "break-confirming",
      label: "Break detected: confirming",
      tone: "warn",
      meaning:
        "The pool is locked to corrective trades. If the price is still more than the hard threshold from Chainlink when the timer ends, the URU vault is drawn down. If it recovers, nothing is taken.",
      confirmInSeconds,
    };
  }
  if (stabilizing) {
    return {
      id: "stabilizing",
      label: "Stabilizing",
      tone: "warn",
      meaning: "The market just opened. Fees stay flat for a few minutes while prices settle.",
    };
  }
  if (oracleSkewed) {
    return {
      id: "skewed",
      label: "Feeds out of sync",
      tone: "warn",
      meaning: "The two Chainlink feeds are far apart in time. Swaps use the flat base fee and new deposits wait.",
    };
  }
  if (pool.tradingHours === "equity-hours" && marketOpen === false) {
    return {
      id: "closed",
      label: "Market closed",
      tone: "warn",
      meaning: "The stock market is closed. Swaps stay open at a flat fee, new deposits wait for the open, and withdrawals always work.",
    };
  }
  return {
    id: "in-band",
    label: "Live",
    tone: "pos",
    meaning: "Trading normally. Trades toward the Chainlink price get a discount, trades away from it pay a surcharge.",
  };
}

export function formatCountdown(seconds: number): string {
  if (seconds <= 0) return "ready now";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

/** Selector of `SwapWouldBreakPool(int256,int256)`. Searched for in wrapped v4 revert data. */
const SWAP_WOULD_BREAK_SELECTOR = "c1401fcc";
/** Selector of `AdversarialSwapDuringBreak()`. */
const ADVERSARIAL_DURING_BREAK_SELECTOR = "6a18fbfe";

export const SWAP_TOO_LARGE_MESSAGE =
  "This trade is too large for the pool right now: it would push the price more than 15% from Chainlink. Try a smaller amount.";
export const SWAP_ADVERSARIAL_DURING_BREAK_MESSAGE =
  "The pool is in a structural break, so only trades that move the price back toward Chainlink are allowed. Try the other direction.";

/**
 * Turn a swap simulation error into a plain-English message when it is one of the hook's
 * user-facing reverts. v4 wraps hook reverts, so the hook's error name is usually not decoded;
 * we look for the raw selector in the error text as well as the name.
 */
export function friendlySwapError(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const lower = raw.toLowerCase();
  if (lower.includes("swapwouldbreakpool") || lower.includes(SWAP_WOULD_BREAK_SELECTOR)) return SWAP_TOO_LARGE_MESSAGE;
  if (lower.includes("adversarialswapduringbreak") || lower.includes(ADVERSARIAL_DURING_BREAK_SELECTOR)) {
    return SWAP_ADVERSARIAL_DURING_BREAK_MESSAGE;
  }
  return undefined;
}

/** A live pool has no liquidity when its on-chain LP share supply is zero, or (before that read
 *  arrives) when the manifest marks it unseeded. */
export function needsLiquidity(pool: Pick<CuratedPool, "status" | "seeded">, totalShares?: bigint): boolean {
  if (pool.status !== "live") return false;
  if (totalShares !== undefined) return totalShares === 0n;
  return !pool.seeded;
}

export const NO_LIQUIDITY_MESSAGE =
  "This pool has no liquidity yet. Be the first LP: add liquidity, Zap, or migrate a Uniswap v3 position.";

/** Ask the terminal action rail to switch tabs (it listens for this event). */
export function openActionTab(tab: "trade" | "provide" | "stake" | "rebate"): void {
  window.dispatchEvent(new CustomEvent("woolfi:open-tab", {detail: tab}));
}

/** Launch-liquidity line. States the live fact only once pools are actually live. */
export function launchLiquidityCopy(anyLive: boolean): string {
  return anyLive
    ? "All 18 pools are live. WETH/USDG and NVDA/USDG are seeded at launch; the rest are open for the first liquidity providers, including one-click migration from Uniswap v3."
    : "At launch all 18 pools go live together. WETH/USDG and NVDA/USDG are seeded; the rest open for the first liquidity providers, including one-click migration from Uniswap v3.";
}
