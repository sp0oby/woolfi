/** Pure decision math. No I/O, fully unit-tested. */

export const WAD = 10n ** 18n;

export type Direction = {
  /** WoolFi swap direction: true sells token0 for token1. */
  zeroForOne: boolean;
  /** Index of the token sold into WoolFi (0 or 1); profit is paid in this token. */
  tokenInIndex: 0 | 1;
};

/**
 * Corrective direction from the hook's drift. drift = (poolPrice - fair) / fair where price is
 * token1 per token0. Negative drift: token0 is cheap on WoolFi, so buy token0 (sell token1).
 * Positive drift: token0 is rich, so sell token0. Returns null inside the dead band.
 */
export function correctiveDirection(driftBps: bigint, minDriftBps: number): Direction | null {
  const abs = driftBps < 0n ? -driftBps : driftBps;
  if (abs < BigInt(minDriftBps)) return null;
  return driftBps < 0n ? {zeroForOne: false, tokenInIndex: 1} : {zeroForOne: true, tokenInIndex: 0};
}

/** Convert a USD size into raw token units using a WAD USD price. */
export function usdToTokenUnits(usd: number, priceWad: bigint, decimals: number): bigint {
  if (priceWad === 0n) return 0n;
  const usdWad = BigInt(Math.round(usd * 1e6)) * 10n ** 12n;
  return (usdWad * 10n ** BigInt(decimals)) / priceWad;
}

/** Raw token units to USD (float, for logs and thresholds only). */
export function tokenUnitsToUsd(amount: bigint, priceWad: bigint, decimals: number): number {
  const wad = (amount * priceWad) / 10n ** BigInt(decimals);
  return Number(wad / 10n ** 12n) / 1e6;
}

export type Candidate = {amountIn: bigint; profit: bigint; gasCostUsd: number; profitUsd: number};

/** Best candidate by net USD (profit minus gas). Null when nothing nets positive. */
export function pickBest(candidates: Candidate[]): Candidate | null {
  let best: Candidate | null = null;
  for (const c of candidates) {
    const net = c.profitUsd - c.gasCostUsd;
    if (net <= 0) continue;
    if (!best || net > best.profitUsd - best.gasCostUsd) best = c;
  }
  return best;
}
