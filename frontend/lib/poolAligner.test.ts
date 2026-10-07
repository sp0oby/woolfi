import {describe, expect, it} from "vitest";

import {needsAlign} from "./poolAligner";

describe("needsAlign", () => {
  it("is true only for an empty pool that is off fair, when an aligner exists", () => {
    expect(needsAlign({liquidity: 0n, driftBps: -909n, alignerDeployed: true})).toBe(true);
    expect(needsAlign({liquidity: 0n, driftBps: 3, alignerDeployed: true})).toBe(true);
    expect(needsAlign({liquidity: 0n, driftBps: 0n, alignerDeployed: true})).toBe(false);
    expect(needsAlign({liquidity: 1n, driftBps: -909n, alignerDeployed: true})).toBe(false);
    expect(needsAlign({liquidity: 0n, driftBps: -909n, alignerDeployed: false})).toBe(false);
    expect(needsAlign({liquidity: 0n, driftBps: undefined, alignerDeployed: true})).toBe(false);
  });
});
