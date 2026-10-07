import {describe, expect, it} from "vitest";

import {derivePoolState, friendlySwapError, needsLiquidity, SWAP_TOO_LARGE_MESSAGE} from "./poolState";

const live = {status: "live", seeded: true, tradingHours: "equity-hours"} as const;

describe("derivePoolState", () => {
  it("shows pre-launch before deployment", () => {
    expect(derivePoolState({pool: {...live, status: "pending", seeded: false}, deployed: false}).id).toBe("pre-launch");
  });

  it("flags an unseeded live pool, preferring the on-chain share supply", () => {
    expect(derivePoolState({pool: {...live, seeded: false}, deployed: true}).id).toBe("needs-liquidity");
    expect(derivePoolState({pool: {...live, seeded: false}, deployed: true, totalShares: 5n}).id).toBe("in-band");
    expect(derivePoolState({pool: live, deployed: true, totalShares: 0n}).id).toBe("needs-liquidity");
  });

  it("walks the two-step break states", () => {
    const base = {pool: live, deployed: true, totalShares: 1n, nowSeconds: 1_000};
    const confirming = derivePoolState({
      ...base,
      breakStatus: {broken: true, confirmed: false, detectedAt: 900, confirmReadyAt: 4_600, waitingForMarketOpen: false},
    });
    expect(confirming.id).toBe("break-confirming");
    expect(confirming.confirmInSeconds).toBe(3_600);
    expect(
      derivePoolState({
        ...base,
        breakStatus: {broken: true, confirmed: false, detectedAt: 900, confirmReadyAt: undefined, waitingForMarketOpen: true},
      }).id,
    ).toBe("break-waiting-open");
    expect(
      derivePoolState({
        ...base,
        breakStatus: {broken: true, confirmed: true, detectedAt: 900, confirmReadyAt: undefined, waitingForMarketOpen: false},
      }).id,
    ).toBe("break-confirmed");
  });

  it("reports a closed equity market", () => {
    expect(derivePoolState({pool: live, deployed: true, totalShares: 1n, marketOpen: false}).id).toBe("closed");
  });
});

describe("friendlySwapError", () => {
  it("maps the break-guard selector inside wrapped revert data", () => {
    expect(friendlySwapError("Execution reverted [data 0x90bfb865000000c1401fcc0000]")).toBe(SWAP_TOO_LARGE_MESSAGE);
    expect(friendlySwapError('reverted with "SwapWouldBreakPool(1, 1600)"')).toBe(SWAP_TOO_LARGE_MESSAGE);
  });

  it("leaves unrelated errors alone", () => {
    expect(friendlySwapError("ERC20: insufficient allowance")).toBeUndefined();
    expect(friendlySwapError(undefined)).toBeUndefined();
  });
});

describe("needsLiquidity", () => {
  it("is false for pools that are not live", () => {
    expect(needsLiquidity({status: "pending", seeded: false})).toBe(false);
  });
});
