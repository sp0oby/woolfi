import {mkdtempSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {describe, expect, it} from "vitest";

import {keepPools} from "../src/keep";
import {isDeployed, loadManifest} from "../src/manifest";

const hook = "0x1111111111111111111111111111111111111111";

describe("keeper manifest", () => {
  it("refuses a partial live catalog", () => {
    const path = join(mkdtempSync(join(tmpdir(), "woolfi-keeper-")), "robinhood.json");
    writeFileSync(
      path,
      JSON.stringify({
        chainId: 4663,
        hook,
        launchStatus: "live",
        pools: [
          {
            slug: "mstr-usdg",
            poolId: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            token0: "0x2222222222222222222222222222222222222222",
            token1: "0x3333333333333333333333333333333333333333",
            tickSpacing: 60,
            startBlock: 123,
            receipt: `0x${"a".repeat(64)}`,
          },
          {slug: "pending", poolId: "0x0000000000000000000000000000000000000000000000000000000000000000"},
        ],
      }),
    );
    const manifest = loadManifest(path);
    expect(isDeployed(manifest)).toBe(false);
    expect(manifest.pools).toHaveLength(1);
    expect(manifest.pools[0]?.key.hooks).toBe(hook.toLowerCase());
  });

  it("treats an empty pending manifest as not deployed", () => {
    const path = join(mkdtempSync(join(tmpdir(), "woolfi-keeper-")), "robinhood.json");
    writeFileSync(path, JSON.stringify({chainId: 4663, hook: "0x0000000000000000000000000000000000000000", pools: []}));
    expect(isDeployed(loadManifest(path))).toBe(false);
  });

  it("accepts exactly sixteen distinct live pools", () => {
    const pools = Array.from({length: 16}, (_, index) => ({
      slug: `pool-${index}`,
      poolId: `0x${(index + 1).toString(16).padStart(64, "0")}` as `0x${string}`,
      startBlock: 123,
      key: {
        currency0: "0x2222222222222222222222222222222222222222" as const,
        currency1: "0x3333333333333333333333333333333333333333" as const,
        fee: 0x800000,
        tickSpacing: 60,
        hooks: hook as `0x${string}`,
      },
    }));
    expect(isDeployed({chainId: 4663, hook: hook as `0x${string}`, pools})).toBe(true);
  });
});

describe("keepPools", () => {
  it("simulates each pool and does not broadcast in dry-run", async () => {
    const calls: string[] = [];
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: async ({functionName}) => {
            calls.push(String(functionName));
            return {request: {functionName}} as never;
          },
        },
        walletClient: {
          writeContract: async () => {
            throw new Error("dry-run must not write");
          },
        },
      },
      [
        {
          slug: "mstr-usdg",
          poolId: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          startBlock: 123,
          key: {
            currency0: "0x2222222222222222222222222222222222222222",
            currency1: "0x3333333333333333333333333333333333333333",
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook,
          },
        },
      ],
      {broadcast: false},
    );
    expect(calls).toEqual(["checkStructuralBreak"]);
    expect(outcomes[0]).toMatchObject({slug: "mstr-usdg", simulated: true, broadcast: false});
  });
});
