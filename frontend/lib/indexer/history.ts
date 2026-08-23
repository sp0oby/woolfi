import {INDEXER_STALE_AFTER_SECONDS} from "./client";

export type SwapClassification = "corrective" | "adversarial" | "neutral";

export type IndexedSwap = {
  id: string;
  blockNumber: bigint;
  timestamp: bigint;
  driftBps: bigint;
  asymmetricActive: boolean;
  structuralBreakTriggered: boolean;
  classification?: SwapClassification;
  txHash: `0x${string}`;
};

export function classifySwaps<T extends {id: string; driftBps: bigint}>(
  rows: T[],
): Array<T & {classification?: SwapClassification}> {
  const enriched: Array<T & {classification?: SwapClassification}> = [];
  let prevAbs: bigint | undefined;
  for (const row of rows) {
    const absDrift = row.driftBps < 0n ? -row.driftBps : row.driftBps;
    let classification: SwapClassification | undefined;
    if (prevAbs !== undefined) {
      if (absDrift < prevAbs) classification = "corrective";
      else if (absDrift > prevAbs) classification = "adversarial";
      else classification = "neutral";
    }
    enriched.push({...row, classification});
    prevAbs = absDrift;
  }
  return enriched;
}

export function txHashFromEventId(id: string): `0x${string}` {
  const [hash] = id.split(/[:-]/);
  return (hash ?? "0x") as `0x${string}`;
}

export function isIndexerStale(
  newestTimestamp: bigint | undefined,
  nowSeconds = Math.floor(Date.now() / 1000),
  maxAge = INDEXER_STALE_AFTER_SECONDS,
): boolean {
  if (newestTimestamp === undefined) return false;
  return nowSeconds - Number(newestTimestamp) > maxAge;
}

export function parseIndexedInt(value: string | number | bigint): bigint {
  return BigInt(value);
}
