import {hookAbi, keeperAbi} from "./abi.js";
import type {LivePool} from "./manifest.js";

export type PoolOutcome = {
  slug: string;
  poolId: `0x${string}`;
  action: "checkStructuralBreak" | "keep";
  simulated: boolean;
  broadcast: boolean;
  hash?: `0x${string}`;
  error?: string;
};

export type TickSummary = {
  tick: string;
  pools: number;
  failures: number;
  ready: boolean;
};

export type KeeperClients = {
  publicClient: {
    simulateContract: (args: Record<string, unknown>) => Promise<{request: Record<string, unknown>}>;
  };
  walletClient?: {
    writeContract: (args: Record<string, unknown>) => Promise<`0x${string}`>;
  };
};

export async function keepPools(
  clients: KeeperClients,
  pools: LivePool[],
  options: {keeper?: `0x${string}`; broadcast: boolean},
): Promise<PoolOutcome[]> {
  const outcomes: PoolOutcome[] = [];
  for (const pool of pools) {
    const action = options.keeper ? "keep" : "checkStructuralBreak";
    try {
      if (options.keeper) {
        const simulated = await clients.publicClient.simulateContract({
          address: options.keeper,
          abi: keeperAbi,
          functionName: "keep",
          args: [pool.key],
        });
        const hash = options.broadcast && clients.walletClient
          ? await clients.walletClient.writeContract(simulated.request)
          : undefined;
        outcomes.push({slug: pool.slug, poolId: pool.poolId, action, simulated: true, broadcast: !!hash, hash});
      } else {
        const simulated = await clients.publicClient.simulateContract({
          address: pool.key.hooks,
          abi: hookAbi,
          functionName: "checkStructuralBreak",
          args: [pool.key],
        });
        const hash = options.broadcast && clients.walletClient
          ? await clients.walletClient.writeContract(simulated.request)
          : undefined;
        outcomes.push({slug: pool.slug, poolId: pool.poolId, action, simulated: true, broadcast: !!hash, hash});
      }
    } catch (error) {
      outcomes.push({
        slug: pool.slug,
        poolId: pool.poolId,
        action,
        simulated: false,
        broadcast: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return outcomes;
}

/** Roll a tick's outcomes into the shape the exit code and alert webhook key off. */
export function summarize(outcomes: PoolOutcome[], tick: string = new Date().toISOString()): TickSummary {
  const failures = outcomes.filter((o) => !o.simulated).length;
  return {tick, pools: outcomes.length, failures, ready: failures === 0};
}

/**
 * POST the summary to an alert webhook. Never throws: a broken webhook must not take the
 * keeper down with it. Returns true on 2xx, false otherwise.
 */
export async function notifyWebhook(url: string, summary: TickSummary, timeoutMs = 5_000): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(summary),
      signal: controller.signal,
    });
    if (!response.ok) {
      console.error(JSON.stringify({alertWebhook: "non-2xx", status: response.status}));
      return false;
    }
    return true;
  } catch (error) {
    console.error(
      JSON.stringify({alertWebhook: "failed", error: error instanceof Error ? error.message : String(error)}),
    );
    return false;
  } finally {
    clearTimeout(timer);
  }
}
