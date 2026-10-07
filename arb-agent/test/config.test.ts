import {mkdtempSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {describe, expect, it} from "vitest";

import {loadPools} from "../src/config";

const hook = "0x1111111111111111111111111111111111111111";

function manifestFile(launchStatus: string, count: number): string {
  const pools = Array.from({length: count}, (_, index) => ({
    slug: `pool-${index}`,
    token0: `0x${(index + 0x100).toString(16).padStart(40, "0")}`,
    token1: `0x${(index + 0x200).toString(16).padStart(40, "0")}`,
    tickSpacing: 60,
    oracle0: "0x3333333333333333333333333333333333333333",
    oracle1: "0x4444444444444444444444444444444444444444",
    seeded: index < 2,
  }));
  const path = join(mkdtempSync(join(tmpdir(), "woolfi-arb-")), "robinhood.json");
  writeFileSync(path, JSON.stringify({chainId: 4663, hook, launchStatus, pools}));
  return path;
}

describe("loadPools", () => {
  it("returns nothing while the launch is pending", () => {
    expect(loadPools(manifestFile("pending", 18)).pools).toHaveLength(0);
  });

  it("loads every live pool, seeded or not", () => {
    const {chainId, pools} = loadPools(manifestFile("live", 18));
    expect(chainId).toBe(4663);
    expect(pools).toHaveLength(18);
    expect(pools.every((pool) => pool.key.hooks === hook)).toBe(true);
  });
});
