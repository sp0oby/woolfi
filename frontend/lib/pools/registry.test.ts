import {describe, expect, it} from "vitest";

import {
  buildPoolRegistry,
  defaultPool,
  filterPools,
  findPoolBySlug,
  poolRegistry,
  validatePoolRegistry,
} from "./registry";

const NONZERO = "0x1111111111111111111111111111111111111111";
const core = {
  poolManager: "0x8366a39cc670b4001a1121b8f6a443a643e40951",
  hook: NONZERO,
  positionManager: "0x2222222222222222222222222222222222222222",
  stakingToken: "0x9fbe210007dDd8389f98d0253018e65CC48b9D24",
};

function deployed(slug: string, a: `0x${string}`, b: `0x${string}`, id: number, seeded: boolean) {
  const [token0, token1] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  return {
    slug,
    poolId: `0x${id.toString(16).padStart(64, "0")}` as `0x${string}`,
    token0,
    token1,
    oracle0: "0x3333333333333333333333333333333333333333" as const,
    oracle1: "0x4444444444444444444444444444444444444444" as const,
    marketHours:
      slug === "weth-usdg"
        ? ("0x0000000000000000000000000000000000000000" as const)
        : ("0x6666666666666666666666666666666666666666" as const),
    vault: `0x${(id + 0x5000).toString(16).padStart(40, "0")}` as `0x${string}`,
    tickSpacing: 60,
    baseFeeBps: 30,
    toleranceBps: 500,
    hardThresholdBps: 1500,
    drawdownBps: 2000,
    vaultFeeBps: 2000,
    treasuryFeeBps: 1000,
    startBlock: 123,
    seeded,
  };
}

const seedSet = new Set(["weth-usdg", "nvda-usdg"]);
const allEighteen = poolRegistry.map((pool, index) =>
  deployed(pool.slug, pool.base.address, pool.quote.address, index + 1, seedSet.has(pool.slug)),
);

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

  it("defaults to a seeded live pool, then any live pool, then the first candidate", () => {
    const expected =
      poolRegistry.find((pool) => pool.status === "live" && pool.seeded) ??
      poolRegistry.find((pool) => pool.status === "live") ??
      poolRegistry[0];
    expect(defaultPool.slug).toBe(expected.slug);
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

describe("coordinated launch with a seed set", () => {
  it("puts all 18 live together and flags only the seed set as seeded", () => {
    const registry = buildPoolRegistry({...core, launchStatus: "live", pools: allEighteen});
    expect(registry.filter((pool) => pool.status === "live")).toHaveLength(18);
    expect(registry.filter((pool) => pool.seeded).map((pool) => pool.slug).sort()).toEqual([
      "nvda-usdg",
      "weth-usdg",
    ]);
    expect(registry.filter((pool) => pool.status === "live" && !pool.seeded)).toHaveLength(16);
    expect(registry.every((pool) => pool.deployment)).toBe(true);
    expect(validatePoolRegistry(registry)).toEqual([]);
  });

  it("keeps everything pending while launchStatus is pending, even with all 18 deployed", () => {
    const registry = buildPoolRegistry({...core, launchStatus: "pending", pools: allEighteen});
    expect(registry.filter((pool) => pool.status === "live")).toHaveLength(0);
    expect(registry.some((pool) => pool.seeded || pool.deployment)).toBe(false);
  });

  it("keeps everything pending when fewer than 18 pools are deployed", () => {
    const registry = buildPoolRegistry({...core, launchStatus: "live", pools: allEighteen.slice(0, 17)});
    expect(registry.filter((pool) => pool.status === "live")).toHaveLength(0);
  });

  it("keeps everything pending when a core address is zero", () => {
    const registry = buildPoolRegistry({
      ...core,
      hook: "0x0000000000000000000000000000000000000000",
      launchStatus: "live",
      pools: allEighteen,
    });
    expect(registry.filter((pool) => pool.status === "live")).toHaveLength(0);
  });

  it("treats an incomplete pool deployment as blocking the coordinated launch", () => {
    const broken = allEighteen.map((pool, index) =>
      index === 3 ? {...pool, vault: "0x0000000000000000000000000000000000000000" as const} : pool,
    );
    const registry = buildPoolRegistry({...core, launchStatus: "live", pools: broken});
    expect(registry.filter((pool) => pool.status === "live")).toHaveLength(0);
  });
});
