import {describe, expect, it} from "vitest";

import {
  applySlippage,
  approvalCovers,
  deadlineIn,
  inputsKey,
  isWrongNetwork,
  parseSlippageBps,
  readKeyed,
  uruFromShares,
} from "./txGuards";

const TOKEN_A = "0x00000000000000000000000000000000000000aa" as const;
const TOKEN_B = "0x00000000000000000000000000000000000000bb" as const;
const ROUTER = "0x00000000000000000000000000000000000000cc" as const;
const OTHER = "0x00000000000000000000000000000000000000dd" as const;

describe("wrong-network detection", () => {
  it("flags a connected wallet on another chain", () => {
    expect(isWrongNetwork(true, 1, 4663)).toBe(true);
    expect(isWrongNetwork(true, undefined, 4663)).toBe(true);
  });

  it("is quiet on the right chain or when disconnected", () => {
    expect(isWrongNetwork(true, 4663, 4663)).toBe(false);
    expect(isWrongNetwork(false, 1, 4663)).toBe(false);
  });
});

describe("input-keyed quotes and previews", () => {
  const forward = inputsKey(ROUTER, "pool", true, 10n ** 18n, TOKEN_A);
  const flipped = inputsKey(ROUTER, "pool", false, 10n ** 18n, TOKEN_A);
  const bigger = inputsKey(ROUTER, "pool", true, 2n * 10n ** 18n, TOKEN_A);

  it("distinguishes direction, amount and missing values", () => {
    expect(forward).not.toBe(flipped);
    expect(forward).not.toBe(bigger);
    expect(inputsKey(undefined, 1n)).not.toBe(inputsKey("undefined", 1n));
  });

  it("exposes a result only for the inputs that produced it", () => {
    const result = {key: forward, value: 123n};
    expect(readKeyed(result, forward)).toEqual({value: 123n, error: undefined, fresh: true});
    // After a direction flip or amount change the old quote reads as loading, never as a value.
    expect(readKeyed(result, flipped)).toEqual({value: undefined, error: undefined, fresh: false});
    expect(readKeyed(result, bigger).value).toBeUndefined();
    expect(readKeyed(undefined, forward).fresh).toBe(false);
  });

  it("keys errors the same way", () => {
    const failed = {key: forward, error: "reverted"};
    expect(readKeyed(failed, forward)).toEqual({value: undefined, error: "reverted", fresh: true});
    expect(readKeyed(failed, bigger).error).toBeUndefined();
  });
});

describe("approval coverage", () => {
  const confirmed = {token: TOKEN_A, spender: ROUTER, amount: 100n};

  it("covers the same token and spender up to the approved amount", () => {
    expect(approvalCovers(confirmed, {token: TOKEN_A, spender: ROUTER, amount: 100n})).toBe(true);
    expect(approvalCovers(confirmed, {token: TOKEN_A, spender: ROUTER, amount: 50n})).toBe(true);
    expect(approvalCovers(confirmed, {token: TOKEN_A.toUpperCase() as `0x${string}`, spender: ROUTER, amount: 1n})).toBe(true);
  });

  it("does not cover a larger amount, another token or another spender", () => {
    expect(approvalCovers(confirmed, {token: TOKEN_A, spender: ROUTER, amount: 101n})).toBe(false);
    expect(approvalCovers(confirmed, {token: TOKEN_B, spender: ROUTER, amount: 1n})).toBe(false);
    expect(approvalCovers(confirmed, {token: TOKEN_A, spender: OTHER, amount: 1n})).toBe(false);
    expect(approvalCovers(undefined, {token: TOKEN_A, spender: ROUTER, amount: 1n})).toBe(false);
  });

  it("matches NFT approvals by token id", () => {
    const nft = {token: TOKEN_A, spender: ROUTER, amount: 0n, id: 7n};
    expect(approvalCovers(nft, {token: TOKEN_A, spender: ROUTER, amount: 0n, id: 7n})).toBe(true);
    expect(approvalCovers(nft, {token: TOKEN_A, spender: ROUTER, amount: 0n, id: 8n})).toBe(false);
    expect(approvalCovers(confirmed, {token: TOKEN_A, spender: ROUTER, amount: 0n, id: 7n})).toBe(false);
  });
});

describe("slippage", () => {
  it("parses percent to bps", () => {
    expect(parseSlippageBps("0.5")).toBe(50n);
    expect(parseSlippageBps("1.0")).toBe(100n);
    expect(parseSlippageBps("0.29")).toBe(29n);
    expect(parseSlippageBps("0")).toBe(0n);
  });

  it("caps at 5% and rejects malformed input", () => {
    expect(parseSlippageBps("5")).toBe(500n);
    expect(parseSlippageBps("5.01")).toBeUndefined();
    expect(parseSlippageBps("50")).toBeUndefined();
    expect(parseSlippageBps("")).toBeUndefined();
    expect(parseSlippageBps(".")).toBeUndefined();
    expect(parseSlippageBps("1.2.3")).toBeUndefined();
  });

  it("applies bps to an amount, rounding down", () => {
    expect(applySlippage(10_000n, 100n)).toBe(9_900n);
    expect(applySlippage(999n, 50n)).toBe(994n);
    expect(applySlippage(123n, 0n)).toBe(123n);
  });
});

describe("vault stake valuation", () => {
  it("values shares at shares * totalStaked / totalShares", () => {
    expect(uruFromShares(100n, 200n, 100n)).toBe(200n);
    // After a 10% drawdown, the same shares are worth 10% less URU.
    expect(uruFromShares(50n, 90n, 100n)).toBe(45n);
  });

  it("handles missing reads and an empty vault", () => {
    expect(uruFromShares(undefined, 1n, 1n)).toBeUndefined();
    expect(uruFromShares(1n, undefined, 1n)).toBeUndefined();
    expect(uruFromShares(0n, 0n, 0n)).toBe(0n);
  });
});

describe("deadlines", () => {
  it("is unix seconds plus the window", () => {
    expect(deadlineIn(20, 1_000_000_500)).toBe(1_000_000n + 1_200n);
  });
});
