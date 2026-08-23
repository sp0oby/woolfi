import {describe, expect, it} from "vitest";

import {classifySwaps, isIndexerStale, txHashFromEventId} from "./history";

describe("classifySwaps", () => {
  it("labels later rows against the previous absolute drift", () => {
    const rows = classifySwaps([
      {id: "a", driftBps: 80n},
      {id: "b", driftBps: 20n},
      {id: "c", driftBps: -40n},
      {id: "d", driftBps: -40n},
    ]);
    expect(rows.map((row) => row.classification)).toEqual([
      undefined,
      "corrective",
      "adversarial",
      "neutral",
    ]);
  });
});

describe("indexer freshness", () => {
  it("is stale only after the configured age", () => {
    expect(isIndexerStale(1_000n, 1_000 + 60, 120)).toBe(false);
    expect(isIndexerStale(1_000n, 1_000 + 121, 120)).toBe(true);
    expect(isIndexerStale(undefined, 2_000, 120)).toBe(false);
  });

  it("extracts the transaction hash from an event id", () => {
    expect(txHashFromEventId("0xabc-3")).toBe("0xabc");
  });
});
