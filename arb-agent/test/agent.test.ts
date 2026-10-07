import {describe, expect, it, vi} from "vitest";

import {runTick} from "../src/agent";
import type {AgentConfig, ArbPool} from "../src/config";
import {explain} from "../src/explain";
import {correctiveDirection, pickBest, tokenUnitsToUsd, usdToTokenUnits, WAD} from "../src/math";
import type {ChainReader} from "../src/scan";

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const pool: ArbPool = {
  slug: "weth-usdg",
  key: {
    currency0: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
    currency1: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    fee: 0x800000,
    tickSpacing: 60,
    hooks: "0x1111111111111111111111111111111111111111",
  },
  oracle0: "0x2222222222222222222222222222222222222222",
  oracle1: "0x3333333333333333333333333333333333333333",
};

function cfg(over: Partial<AgentConfig> = {}): AgentConfig {
  return {
    rpcUrl: "x",
    manifestPath: "x",
    executor: "0x4444444444444444444444444444444444444444",
    broadcast: false,
    cadenceMs: 1000,
    minProfitUsd: 1,
    minDriftBps: 40,
    sizesUsd: [500, 1000, 2000],
    v3Factory: "0x5555555555555555555555555555555555555555",
    v3Quoter: "0x6666666666666666666666666666666666666666",
    explainEveryTicks: 10,
    ...over,
  };
}

/** Mock chain: WETH $2,500 (18dp), USDG $1 (6dp), drift -662 bps, one v3 pool at fee 100. */
function mockChain(profitFor: (amountIn: bigint) => bigint): ChainReader & {simulated: bigint[]} {
  const simulated: bigint[] = [];
  return {
    simulated,
    readContract: async (a) => {
      switch (a.functionName) {
        case "currentDrift":
          return -662n;
        case "getPrice":
          return a.address === pool.oracle0 ? 2500n * WAD : WAD;
        case "decimals":
          return a.address === pool.key.currency0 ? 18 : 6;
        case "getPool":
          return (a.args as unknown[])[2] === 100 ? "0x7777777777777777777777777777777777777777" : ZERO;
        case "liquidity":
          return 10n ** 20n;
        case "latestRoundData":
          return [1n, 2500n * 10n ** 8n, 0n, 0n, 1n];
        default:
          throw new Error(`unexpected read ${String(a.functionName)}`);
      }
    },
    simulateContract: async (a) => {
      if (a.functionName === "quoteExactInputSingle") return {result: [99_000_000n, 0n, 0, 0n], request: {}};
      const amountIn = ((a.args as {amountIn: bigint}[])[0]).amountIn;
      simulated.push(amountIn);
      return {result: profitFor(amountIn), request: {functionName: "execute"}};
    },
    estimateContractGas: async () => 400_000n,
    getGasPrice: async () => 10_000_000n, // 0.01 gwei: ~$0.01 of gas
  };
}

describe("decision math", () => {
  it("buys token0 when the pool is below fair and sells it when above", () => {
    expect(correctiveDirection(-662n, 40)).toEqual({zeroForOne: false, tokenInIndex: 1});
    expect(correctiveDirection(500n, 40)).toEqual({zeroForOne: true, tokenInIndex: 0});
  });

  it("stays idle inside the dead band", () => {
    expect(correctiveDirection(39n, 40)).toBeNull();
    expect(correctiveDirection(-39n, 40)).toBeNull();
  });

  it("converts USD sizes to token units and back", () => {
    expect(usdToTokenUnits(1000, WAD, 6)).toBe(1_000_000_000n);
    expect(usdToTokenUnits(2500, 2500n * WAD, 18)).toBe(WAD);
    expect(tokenUnitsToUsd(52_996_251n, WAD, 6)).toBeCloseTo(52.996251, 5);
  });

  it("picks the best size net of gas and rejects gas-negative candidates", () => {
    const best = pickBest([
      {amountIn: 1n, profit: 0n, profitUsd: 5, gasCostUsd: 1},
      {amountIn: 2n, profit: 0n, profitUsd: 30, gasCostUsd: 1},
      {amountIn: 3n, profit: 0n, profitUsd: 31, gasCostUsd: 10},
    ]);
    expect(best?.amountIn).toBe(2n);
    expect(pickBest([{amountIn: 1n, profit: 0n, profitUsd: 0.5, gasCostUsd: 1}])).toBeNull();
  });
});

describe("runTick", () => {
  // Profit peaks at the $1,000 size, mirroring a curve that overshoots fair at larger sizes.
  const curve = (amountIn: bigint) => (amountIn === 1_000_000_000n ? 40_000_000n : 10_000_000n);

  it("simulates every size, picks the best, and never sends in dry-run", async () => {
    const chain = mockChain(curve);
    const writer = {writeContract: vi.fn(async () => "0xabc" as const)};
    const [log] = await runTick(chain, writer, [pool], cfg(), "0x000000000000000000000000000000000000dEaD");
    expect(chain.simulated).toEqual([500_000_000n, 1_000_000_000n, 2_000_000_000n]);
    expect(log).toMatchObject({action: "simulated", zeroForOne: false, v3Fee: 100, amountIn: "1000000000", profitUsd: 40});
    expect(writer.writeContract).not.toHaveBeenCalled();
  });

  it("sends only when broadcasting and net profit clears the floor", async () => {
    const writer = {writeContract: vi.fn(async () => `0x${"a".repeat(64)}` as `0x${string}`)};
    const [log] = await runTick(mockChain(curve), writer, [pool], cfg({broadcast: true}), "0x000000000000000000000000000000000000dEaD");
    expect(log.action).toBe("executed");
    expect(writer.writeContract).toHaveBeenCalledTimes(1);

    const writer2 = {writeContract: vi.fn(async () => "0xabc" as const)};
    const [log2] = await runTick(mockChain(curve), writer2, [pool], cfg({broadcast: true, minProfitUsd: 1000}), "0x000000000000000000000000000000000000dEaD");
    expect(log2.action).toBe("simulated");
    expect(writer2.writeContract).not.toHaveBeenCalled();
  });

  it("reports no-executor without simulating when no executor is configured", async () => {
    const chain = mockChain(curve);
    const [log] = await runTick(chain, undefined, [pool], cfg({executor: undefined}), "0x000000000000000000000000000000000000dEaD");
    expect(log.action).toBe("no-executor");
    expect(chain.simulated).toEqual([]);
  });

  it("isolates a failing pool", async () => {
    const chain = mockChain(curve);
    chain.readContract = async () => {
      throw new Error("rpc down");
    };
    const [log] = await runTick(chain, undefined, [pool], cfg(), "0x000000000000000000000000000000000000dEaD");
    expect(log).toMatchObject({action: "error", error: "rpc down"});
  });
});

describe("explain (optional AI layer)", () => {
  const logs = [{slug: "weth-usdg", driftBps: "-662", action: "simulated" as const}];

  it("is skipped entirely without an API key", async () => {
    const fetchMock = vi.fn();
    const out = await explain(logs, {}, {fetch: fetchMock as never, log: () => {}});
    expect(out).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("swallows API errors and network failures", async () => {
    const lines: string[] = [];
    const bad = vi.fn(async () => new Response("nope", {status: 500}));
    expect(await explain(logs, {apiKey: "k"}, {fetch: bad as never, log: (l) => lines.push(l)})).toBeNull();
    const boom = vi.fn(async () => {
      throw new Error("offline");
    });
    expect(await explain(logs, {apiKey: "k"}, {fetch: boom as never, log: (l) => lines.push(l)})).toBeNull();
    expect(lines.some((l) => l.includes("api-error"))).toBe(true);
    expect(lines.some((l) => l.includes("offline"))).toBe(true);
  });

  it("returns the summary text and calls the Messages API with the right headers", async () => {
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = init.headers as Record<string, string>;
      expect(headers["x-api-key"]).toBe("k");
      expect(headers["anthropic-version"]).toBe("2023-06-01");
      expect(JSON.parse(String(init.body)).model).toBe("claude-sonnet-4-5");
      return new Response(JSON.stringify({content: [{type: "text", text: "Did a thing. Because. Nothing odd."}]}), {status: 200});
    });
    const out = await explain(logs, {apiKey: "k"}, {fetch: fetchMock as never, log: () => {}});
    expect(out).toBe("Did a thing. Because. Nothing odd.");
  });
});
