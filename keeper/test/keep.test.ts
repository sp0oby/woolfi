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

  it("reads an optional pool aligner and ignores a zero placeholder", () => {
    const dir = mkdtempSync(join(tmpdir(), "woolfi-keeper-"));
    const set = join(dir, "set.json");
    const zero = join(dir, "zero.json");
    writeFileSync(set, JSON.stringify({chainId: 4663, hook, poolAligner: "0xABCDEF0000000000000000000000000000000001", pools: []}));
    writeFileSync(zero, JSON.stringify({chainId: 4663, hook, poolAligner: "0x0000000000000000000000000000000000000000", pools: []}));
    expect(loadManifest(set).poolAligner).toBe("0xabcdef0000000000000000000000000000000001");
    expect(loadManifest(zero).poolAligner).toBeUndefined();
  });

  it("treats an empty pending manifest as not deployed", () => {
    const path = join(mkdtempSync(join(tmpdir(), "woolfi-keeper-")), "robinhood.json");
    writeFileSync(path, JSON.stringify({chainId: 4663, hook: "0x0000000000000000000000000000000000000000", pools: []}));
    expect(isDeployed(loadManifest(path))).toBe(false);
  });

  it("accepts exactly eighteen distinct live pools and rejects duplicates or a subset", () => {
    const key = {
      currency0: "0x2222222222222222222222222222222222222222" as const,
      currency1: "0x3333333333333333333333333333333333333333" as const,
      fee: 0x800000,
      tickSpacing: 60,
      hooks: hook as `0x${string}`,
    };
    const pools = Array.from({length: 18}, (_, index) => ({
      slug: `pool-${index}`,
      poolId: `0x${(index + 1).toString(16).padStart(64, "0")}` as `0x${string}`,
      startBlock: 123,
      key,
    }));
    const h = hook as `0x${string}`;
    expect(isDeployed({chainId: 4663, hook: h, pools})).toBe(true);
    expect(isDeployed({chainId: 4663, hook: h, pools: pools.slice(0, 2)})).toBe(false);
    expect(isDeployed({chainId: 4663, hook: h, pools: [...pools.slice(0, 17), pools[0]]})).toBe(false);
  });

  it("ignores pools while launchStatus is pending", () => {
    const path = join(mkdtempSync(join(tmpdir(), "woolfi-keeper-")), "robinhood.json");
    writeFileSync(
      path,
      JSON.stringify({
        chainId: 4663,
        hook,
        launchStatus: "pending",
        pools: [
          {
            slug: "weth-usdg",
            poolId: `0x${"a".repeat(64)}`,
            token0: "0x2222222222222222222222222222222222222222",
            token1: "0x3333333333333333333333333333333333333333",
            tickSpacing: 60,
            startBlock: 123,
            receipt: `0x${"a".repeat(64)}`,
          },
        ],
      }),
    );
    const manifest = loadManifest(path);
    expect(manifest.pools).toHaveLength(0);
    expect(isDeployed(manifest)).toBe(false);
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
    expect(calls).toEqual(["checkStructuralBreak", "confirmStructuralBreak", "clearRecoveredBreak"]);
    expect(outcomes[0]).toMatchObject({
      slug: "mstr-usdg",
      simulated: true,
      broadcast: false,
      confirm: "simulated",
      recover: "simulated",
    });
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
            if (functionName === "clearRecoveredBreak") {
              throw new Error('reverted with custom error "BreakNotConfirmed()"');
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
    expect(outcomes[1]).toMatchObject({slug: "ready", simulated: true, confirm: "broadcast", recover: "idle"});
    expect(writes).toEqual(["checkStructuralBreak", "checkStructuralBreak", "confirmStructuralBreak"]);
    expect(summarize(outcomes).failures).toBe(0);
  });

  it("treats market-closed / stabilization / skew reverts on break steps as idle", async () => {
    const key = {
      currency0: "0x2222222222222222222222222222222222222222" as const,
      currency1: "0x3333333333333333333333333333333333333333" as const,
      fee: 0x800000,
      tickSpacing: 60,
      hooks: hook as `0x${string}`,
    };
    const reasons = ["MarketClosed()", "StabilizationActive(1, 2)", "OracleTimestampSkew(1, 2, 120)", "OutOfBand()"];
    let i = 0;
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: async ({functionName}) => {
            if (functionName === "checkStructuralBreak") return {request: {}} as never;
            throw new Error(`reverted with custom error "${reasons[i++ % reasons.length]}"`);
          },
        },
      },
      [
        {slug: "a", poolId: `0x${"1".repeat(64)}` as `0x${string}`, startBlock: 1, key},
        {slug: "b", poolId: `0x${"2".repeat(64)}` as `0x${string}`, startBlock: 1, key},
      ],
      {broadcast: false},
    );
    expect(outcomes.map((o) => [o.confirm, o.recover])).toEqual([
      ["idle", "idle"],
      ["idle", "idle"],
    ]);
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

  it("aligns an empty pool first, broadcasting only when the price actually moves", async () => {
    const aligner = "0x9999999999999999999999999999999999999999" as const;
    const key = {
      currency0: "0x2222222222222222222222222222222222222222" as const,
      currency1: "0x3333333333333333333333333333333333333333" as const,
      fee: 0x800000,
      tickSpacing: 60,
      hooks: hook as `0x${string}`,
    };
    const seededKey = {...key};
    const onFairKey = {...key};
    const order: string[] = [];
    const writes: string[] = [];
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: async ({functionName, args}) => {
            const k = (args as [typeof key])[0];
            order.push(String(functionName));
            if (functionName === "align") {
              if (k === seededKey) throw new Error('reverted with custom error "PoolHasLiquidity(1000)"');
              return {result: k !== onFairKey, request: {functionName}} as never;
            }
            if (functionName !== "checkStructuralBreak") throw new Error('custom error "NotStructurallyBroken()"');
            return {request: {functionName}} as never;
          },
        },
        walletClient: {
          writeContract: async (req) => {
            writes.push(String((req as {functionName: string}).functionName));
            return `0x${"e".repeat(64)}`;
          },
        },
      },
      [
        {slug: "empty", poolId: `0x${"1".repeat(64)}` as `0x${string}`, startBlock: 1, key},
        {slug: "seeded", poolId: `0x${"2".repeat(64)}` as `0x${string}`, startBlock: 1, key: seededKey},
        {slug: "on-fair", poolId: `0x${"3".repeat(64)}` as `0x${string}`, startBlock: 1, key: onFairKey},
      ],
      {aligner, broadcast: true},
    );
    expect(order.slice(0, 2)).toEqual(["align", "checkStructuralBreak"]);
    expect(outcomes.map((o) => o.align)).toEqual(["broadcast", "idle", "idle"]);
    expect(writes.filter((w) => w === "align")).toHaveLength(1);
    expect(summarize(outcomes).failures).toBe(0);
  });

  it("treats a paused hook (wrapped selector) as idle but a stale oracle as a failure", async () => {
    const aligner = "0x9999999999999999999999999999999999999999" as const;
    const key = {
      currency0: "0x2222222222222222222222222222222222222222" as const,
      currency1: "0x3333333333333333333333333333333333333333" as const,
      fee: 0x800000,
      tickSpacing: 60,
      hooks: hook as `0x${string}`,
    };
    const staleKey = {...key};
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: async ({functionName, args}) => {
            if (functionName === "align") {
              throw new Error(
                (args as [typeof key])[0] === staleKey
                  ? 'reverted with custom error "StalePrice(1, 2)"'
                  : 'reverted with custom error "WrappedError(0x1111, 0x9e87fac8, 0x9e87fac8, 0x)"',
              );
            }
            return {request: {}} as never;
          },
        },
      },
      [
        {slug: "paused", poolId: `0x${"1".repeat(64)}` as `0x${string}`, startBlock: 1, key},
        {slug: "stale", poolId: `0x${"2".repeat(64)}` as `0x${string}`, startBlock: 1, key: staleKey},
      ],
      {aligner, broadcast: false},
    );
    expect(outcomes[0]).toMatchObject({slug: "paused", simulated: true, align: "idle"});
    expect(outcomes[1]).toMatchObject({slug: "stale", simulated: false});
    expect(summarize(outcomes).failures).toBe(1);
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
