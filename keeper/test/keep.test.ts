import {mkdtempSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {describe, expect, it} from "vitest";

import {keepPools, notifyWebhook, summarize} from "../src/keep";
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

  it("accepts exactly eighteen distinct live pools", () => {
    const pools = Array.from({length: 18}, (_, index) => ({
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
    expect(calls).toEqual(["checkStructuralBreak", "confirmStructuralBreak"]);
    expect(outcomes[0]).toMatchObject({slug: "mstr-usdg", simulated: true, broadcast: false, confirm: "simulated"});
  });

  it("treats a not-ready confirmation as idle, not a failure, and broadcasts a ready one", async () => {
    const key = {
      currency0: "0x2222222222222222222222222222222222222222" as const,
      currency1: "0x3333333333333333333333333333333333333333" as const,
      fee: 0x800000,
      tickSpacing: 60,
      hooks: hook as `0x${string}`,
    };
    const pendingKey = {...key};
    const writes: string[] = [];
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: async ({functionName, args}) => {
            if (functionName === "confirmStructuralBreak" && (args as [typeof key])[0] === pendingKey) {
              throw new Error('reverted with custom error "BreakConfirmationPending(1791300000)"');
            }
            return {request: {functionName}} as never;
          },
        },
        walletClient: {
          writeContract: async (req) => {
            writes.push(String((req as {functionName: string}).functionName));
            return `0x${"f".repeat(64)}`;
          },
        },
      },
      [
        {slug: "pending", poolId: `0x${"1".repeat(64)}` as `0x${string}`, startBlock: 1, key: pendingKey},
        {slug: "ready", poolId: `0x${"2".repeat(64)}` as `0x${string}`, startBlock: 1, key},
      ],
      {broadcast: true},
    );
    expect(outcomes[0]).toMatchObject({slug: "pending", simulated: true, confirm: "idle"});
    expect(outcomes[1]).toMatchObject({slug: "ready", simulated: true, confirm: "broadcast"});
    expect(writes).toEqual(["checkStructuralBreak", "checkStructuralBreak", "confirmStructuralBreak"]);
    expect(summarize(outcomes).failures).toBe(0);
  });

  it("records a simulate failure for one pool and keeps going for the rest", async () => {
    const key = {
      currency0: "0x2222222222222222222222222222222222222222" as const,
      currency1: "0x3333333333333333333333333333333333333333" as const,
      fee: 0x800000,
      tickSpacing: 60,
      hooks: hook as `0x${string}`,
    };
    const boomKey = {...key};
    const pools = [
      {slug: "ok-a", poolId: `0x${"1".repeat(64)}` as `0x${string}`, startBlock: 1, key},
      {slug: "boom", poolId: `0x${"2".repeat(64)}` as `0x${string}`, startBlock: 1, key: boomKey},
      {slug: "ok-b", poolId: `0x${"3".repeat(64)}` as `0x${string}`, startBlock: 1, key},
    ];
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: async ({args}) => {
            if ((args as [typeof key])[0] === boomKey) throw new Error("revert: StructuralBreakActive");
            return {request: {}} as never;
          },
        },
      },
      pools,
      {broadcast: false},
    );
    expect(outcomes.map((o) => o.slug)).toEqual(["ok-a", "boom", "ok-b"]);
    expect(outcomes[1]).toMatchObject({slug: "boom", simulated: false, error: "revert: StructuralBreakActive"});
    const summary = summarize(outcomes, "2026-09-16T00:00:00.000Z");
    expect(summary).toEqual({tick: "2026-09-16T00:00:00.000Z", pools: 3, failures: 1, ready: false});
  });

  it("summarize reports ready when every pool simulated", () => {
    const summary = summarize(
      [
        {slug: "a", poolId: `0x${"1".repeat(64)}`, action: "checkStructuralBreak", simulated: true, broadcast: false},
        {slug: "b", poolId: `0x${"2".repeat(64)}`, action: "checkStructuralBreak", simulated: true, broadcast: false},
      ],
      "t",
    );
    expect(summary).toEqual({tick: "t", pools: 2, failures: 0, ready: true});
  });

  it("notifyWebhook never throws when the endpoint is unreachable", async () => {
    const ok = await notifyWebhook(
      "http://127.0.0.1:9/unreachable",
      {tick: "t", pools: 1, failures: 1, ready: false},
      500,
    );
    expect(ok).toBe(false);
  });
});
