import {describe, expect, it} from "vitest";

import {fmtAmount} from "./format";
import {parseAmount} from "../components/panels/panelHelpers";

describe("token unit handling", () => {
  it("formats six-decimal token amounts", () => {
    expect(fmtAmount(1_234_567n, 6)).toBe("1.2345");
    expect(fmtAmount(1n, 6, 6)).toBe("0.000001");
  });

  it("parses six-decimal input without scaling it as WAD", () => {
    expect(parseAmount("1.234567", 6)).toBe(1_234_567n);
    expect(parseAmount("1.2345678", 6)).toBeUndefined();
  });

  it("keeps LP and WETH values at 18 decimals", () => {
    expect(parseAmount("1.5", 18)).toBe(1_500_000_000_000_000_000n);
  });
});
