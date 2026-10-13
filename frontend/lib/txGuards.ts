/**
 * Pure guards for the transaction panels: network checks, input-keyed quotes, approval coverage,
 * slippage parsing and vault share valuation. Kept free of React/wagmi so they unit-test directly.
 */

type Address = `0x${string}`;

/** Connected to a chain other than the one WoolFi runs on. Disconnected is never "wrong". */
export function isWrongNetwork(isConnected: boolean, accountChainId: number | undefined, expected: number): boolean {
  return isConnected && accountChainId !== expected;
}

/** A value tagged with the inputs that produced it (a quote, a preview, an estimate). */
export type Keyed<T> = {key: string; value?: T; error?: string};

/** Stable key for a set of inputs. bigint/boolean/undefined all stringify unambiguously. */
export function inputsKey(...parts: ReadonlyArray<string | number | bigint | boolean | undefined | null>): string {
  return parts.map((part) => (part === undefined || part === null ? "-" : String(part))).join("|");
}

/**
 * Expose a keyed result only when it was produced for `key`. A result from older inputs reads as
 * "still loading", never as a usable value, so a stale quote can't feed a min-out bound.
 */
export function readKeyed<T>(
  result: Keyed<T> | undefined,
  key: string,
): {value: T | undefined; error: string | undefined; fresh: boolean} {
  if (!result || result.key !== key) return {value: undefined, error: undefined, fresh: false};
  return {value: result.value, error: result.error, fresh: true};
}

/** What an approval transaction granted. `id` is set for an ERC-721 single-token approval. */
export type ApprovalTarget = {token: Address; spender: Address; amount: bigint; id?: bigint};

/** True when a confirmed approval covers the approval the current action needs. */
export function approvalCovers(confirmed: ApprovalTarget | undefined, wanted: ApprovalTarget | undefined): boolean {
  if (!confirmed || !wanted) return false;
  if (confirmed.token.toLowerCase() !== wanted.token.toLowerCase()) return false;
  if (confirmed.spender.toLowerCase() !== wanted.spender.toLowerCase()) return false;
  if (wanted.id !== undefined || confirmed.id !== undefined) return confirmed.id === wanted.id;
  return confirmed.amount >= wanted.amount;
}

/** Hard cap on user slippage tolerance, in basis points (5%). */
export const MAX_SLIPPAGE_BPS = 500n;
/** Tolerances above this (1%) get a visible warning. */
export const SLIPPAGE_WARN_BPS = 100n;
export const DEFAULT_SLIPPAGE = "1.0";

/** "0.5" -> 50 bps. Undefined when empty, malformed, negative or above the 5% cap. */
export function parseSlippageBps(value: string): bigint | undefined {
  if (!value || !/^\d*\.?\d*$/.test(value) || value === ".") return undefined;
  const num = Number(value);
  if (!Number.isFinite(num) || num < 0) return undefined;
  const bps = BigInt(Math.floor(num * 100 + 1e-9));
  return bps > MAX_SLIPPAGE_BPS ? undefined : bps;
}

/** `amount` reduced by `bps` basis points, rounded down. */
export function applySlippage(amount: bigint, bps: bigint): bigint {
  return (amount * (10_000n - bps)) / 10_000n;
}

/** URU value of vault shares: `shares * totalStaked / totalShares` (matches the vault's math). */
export function uruFromShares(
  shares: bigint | undefined,
  totalStaked: bigint | undefined,
  totalShares: bigint | undefined,
): bigint | undefined {
  if (shares === undefined || totalStaked === undefined || totalShares === undefined) return undefined;
  if (totalShares === 0n) return 0n;
  return (shares * totalStaked) / totalShares;
}

/** Unix-seconds deadline `minutes` from now, as the contracts expect. */
export function deadlineIn(minutes: number, nowMs: number = Date.now()): bigint {
  return BigInt(Math.floor(nowMs / 1_000) + minutes * 60);
}
