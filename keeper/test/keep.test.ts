import {mkdtempSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {describe, expect, it} from "vitest";

import {keepPools} from "../src/keep";
import {isDeployed, loadManifest} from "../src/manifest";

const hook = "0x1111111111111111111111111111111111111111";

describe("keeper manifest", () => {
  it("discovers only complete live pools", () => {
    const path = join(mkdtempSync(join(tmpdir(), "woolfi-keeper-")), "robinhood.json");
    writeFileSync(
      path,
      JSON.stringify({
        chainId: 4663,
        hook,
        pools: [
          {
            slug: "mstr-usdg",
            poolId: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            token0: "0x2222222222222222222222222222222222222222",
            token1: "0x3333333333333333333333333333333333333333",
            tickSpacing: 60,
          },
          {slug: "pending", poolId: "0x0000000000000000000000000000000000000000000000000000000000000000"},
        ],
      }),
    );
    const manifest = loadManifest(path);
    expect(isDeployed(manifest)).toBe(true);
    expect(manifest.pools).toHaveLength(1);
    expect(manifest.pools[0]?.key.hooks).toBe(hook.toLowerCase());
  });

  it("treats an empty pending manifest as not deployed", () => {
    const path = join(mkdtempSync(join(tmpdir(), "woolfi-keeper-")), "robinhood.json");
    writeFileSync(path, JSON.stringify({chainId: 4663, hook: "0x0000000000000000000000000000000000000000", pools: []}));
    expect(isDeployed(loadManifest(path))).toBe(false);
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
