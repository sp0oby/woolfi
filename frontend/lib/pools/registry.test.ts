import {describe, expect, it} from "vitest";

import {defaultPool, filterPools, findPoolBySlug, poolRegistry, validatePoolRegistry} from "./registry";

describe("Robinhood pool registry", () => {
  it("contains unique, valid candidate definitions", () => {
    expect(poolRegistry).toHaveLength(18);
    expect(validatePoolRegistry()).toEqual([]);
  });

  it("resolves stable slugs and rejects unknown slugs", () => {
    expect(findPoolBySlug("mstr-usdg")?.base.symbol).toBe("MSTR");
    expect(findPoolBySlug("weth-usdg")?.tradingHours).toBe("always-open");
    expect(findPoolBySlug("not-a-pool")).toBeUndefined();
  });

  it("defaults to a live pool first and otherwise a pending candidate", () => {
    const firstLive = poolRegistry.find((pool) => pool.status === "live");
    expect(defaultPool.slug).toBe((firstLive ?? poolRegistry[0]).slug);
  });

  it("filters by category and natural pair search", () => {
    expect(filterPools(poolRegistry, "", "spread")).toHaveLength(6);
    expect(filterPools(poolRegistry, "weth usdg", "crypto").map((pool) => pool.slug)).toEqual([
      "weth-usdg",
    ]);
  });

  it("detects reversed pair definitions", () => {
    const original = poolRegistry[0];
    const reversed = {
      ...original,
      slug: `${original.quote.symbol.toLowerCase()}-${original.base.symbol.toLowerCase()}`,
      base: original.quote,
      quote: original.base,
    };

    expect(validatePoolRegistry([original, reversed])).toContain(
      `Duplicate or reversed pool pair: ${reversed.slug}`,
    );
  });
});
