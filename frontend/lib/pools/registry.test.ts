import {describe, expect, it} from "vitest";

import {defaultPool, filterPools, findPoolBySlug, poolRegistry, validatePoolRegistry} from "./registry";

describe("Robinhood pool registry", () => {
  it("contains unique, valid candidate definitions", () => {
    expect(poolRegistry).toHaveLength(18);
    expect(validatePoolRegistry()).toEqual([]);
  });

  it("resolves stable slugs and rejects unknown slugs", () => {
    expect(findPoolBySlug("mstr-usdg")?.base.symbol).toBe("MSTR");
    expect(findPoolBySlug("tsla-usdg")?.base.symbol).toBe("TSLA");
    expect(findPoolBySlug("spy-nvda")?.category).toBe("spread");
    expect(findPoolBySlug("nvda-smh")).toBeUndefined();
    expect(findPoolBySlug("weth-usdg")?.tradingHours).toBe("always-open");
    expect(findPoolBySlug("not-a-pool")).toBeUndefined();
  });

  it("defaults to a live pool first and otherwise a pending candidate", () => {
    const firstLive = poolRegistry.find((pool) => pool.status === "live");
    expect(defaultPool.slug).toBe((firstLive ?? poolRegistry[0]).slug);
  });

  it("uses canonical decimals and preserves coordinated activation", () => {
    expect(findPoolBySlug("weth-usdg")?.base.decimals).toBe(18);
    expect(findPoolBySlug("weth-usdg")?.quote.decimals).toBe(6);
    expect(new Set(poolRegistry.map((pool) => pool.status)).size).toBe(1);
  });

  it("filters by category and natural pair search", () => {
    expect(filterPools(poolRegistry, "", "spread")).toHaveLength(4);
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
