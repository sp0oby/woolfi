import {alignerAbi, hookAbi, keeperAbi} from "./abi.js";
import type {LivePool} from "./manifest.js";

export type PoolOutcome = {
  slug: string;
  poolId: `0x${string}`;
  action: "checkStructuralBreak" | "keep";
  simulated: boolean;
  broadcast: boolean;
  hash?: `0x${string}`;
  error?: string;
  /** Empty-pool realignment, run first when a pool aligner is configured. "idle" = has liquidity,
   *  already on fair, or paused. */
  align?: "idle" | "simulated" | "broadcast";
  alignHash?: `0x${string}`;
  /** Hook-direct mode only: second step of a two-phase break. "idle" = nothing to confirm yet. */
  confirm?: "idle" | "simulated" | "broadcast";
  confirmHash?: `0x${string}`;
  /** Hook-direct mode only: permissionless exit from a confirmed break once drift is back in band. */
  recover?: "idle" | "simulated" | "broadcast";
  recoverHash?: `0x${string}`;
};

// Reverts that mean "nothing to do right now": no break, window not elapsed, already confirmed, not
// yet confirmed, market closed, opening stabilization, skewed legs, or drift still out of band.
// These are the normal steady state, not keeper failures.
const STEP_IDLE =
  /NotStructurallyBroken|BreakConfirmationPending|BreakAlreadyConfirmed|BreakNotConfirmed|MarketClosed|StabilizationActive|OracleTimestampSkew|OutOfBand/;

// Align reverts that are the normal steady state: a seeded pool (PoolHasLiquidity) or a paused hook.
// Hook reverts inside the PoolManager swap arrive as WrappedError carrying the hook selector, so the
// Paused() selector is matched too.
const ALIGN_IDLE = /PoolHasLiquidity|Paused|0x9e87fac8/;

export type TickSummary = {
  tick: string;
  pools: number;
  failures: number;
  ready: boolean;
};

export type KeeperClients = {
  publicClient: {
    simulateContract: (args: Record<string, unknown>) => Promise<{result?: unknown; request: Record<string, unknown>}>;
  };
  walletClient?: {
    writeContract: (args: Record<string, unknown>) => Promise<`0x${string}`>;
  };
};

export async function keepPools(
  clients: KeeperClients,
  pools: LivePool[],
  options: {keeper?: `0x${string}`; aligner?: `0x${string}`; broadcast: boolean},
): Promise<PoolOutcome[]> {
  const outcomes: PoolOutcome[] = [];
  for (const pool of pools) {
    const action = options.keeper ? "keep" : "checkStructuralBreak";
    try {
      // Realign an empty pool first so the break check below sees it on fair, not on a stale launch price.
      const align = options.aligner ? await alignStep(clients, pool, options.aligner, options.broadcast) : undefined;
      const alignFields = align ? {align: align.state, alignHash: align.hash} : {};
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
        outcomes.push({slug: pool.slug, poolId: pool.poolId, action, simulated: true, broadcast: !!hash, hash, ...alignFields});
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
        const confirm = await breakStep(clients, pool, "confirmStructuralBreak", options.broadcast);
        const recover = await breakStep(clients, pool, "clearRecoveredBreak", options.broadcast);
        outcomes.push({
          slug: pool.slug,
          poolId: pool.poolId,
          action,
          simulated: true,
          broadcast: !!hash,
          hash,
          confirm: confirm.state,
          confirmHash: confirm.hash,
          recover: recover.state,
          recoverHash: recover.hash,
          ...alignFields,
        });
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

/**
 * Empty-pool realignment. `align` returns false when the pool is already on fair; that, a seeded
 * pool, or a paused hook resolve to "idle" and are never broadcast. Anything else (for example a stale
 * oracle) throws and counts as a pool failure, as the break check would fail for the same reason.
 */
async function alignStep(
  clients: KeeperClients,
  pool: LivePool,
  aligner: `0x${string}`,
  broadcast: boolean,
): Promise<{state: "idle" | "simulated" | "broadcast"; hash?: `0x${string}`}> {
  let simulated: {result?: unknown; request: Record<string, unknown>};
  try {
    simulated = await clients.publicClient.simulateContract({
      address: aligner,
      abi: alignerAbi,
      functionName: "align",
      args: [pool.key],
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (ALIGN_IDLE.test(message)) return {state: "idle"};
    throw error;
  }
  if (simulated.result === false) return {state: "idle"};
  if (!broadcast || !clients.walletClient) return {state: "simulated"};
  const hash = await clients.walletClient.writeContract(simulated.request);
  return {state: "broadcast", hash};
}

/**
 * Optional break-lifecycle step. `confirmStructuralBreak` fires the drawdown (or clears the break if
 * the price recovered) once the confirmation window has elapsed; `clearRecoveredBreak` unlocks a
 * confirmed break once drift is back in band. Expected "not ready" reverts resolve to "idle";
 * anything else throws and counts as a pool failure.
 */
async function breakStep(
  clients: KeeperClients,
  pool: LivePool,
  functionName: "confirmStructuralBreak" | "clearRecoveredBreak",
  broadcast: boolean,
): Promise<{state: "idle" | "simulated" | "broadcast"; hash?: `0x${string}`}> {
  let simulated: {request: Record<string, unknown>};
  try {
    simulated = await clients.publicClient.simulateContract({
      address: pool.key.hooks,
      abi: hookAbi,
      functionName,
      args: [pool.key],
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (STEP_IDLE.test(message)) return {state: "idle"};
    throw error;
  }
  if (!broadcast || !clients.walletClient) return {state: "simulated"};
  const hash = await clients.walletClient.writeContract(simulated.request);
  return {state: "broadcast", hash};
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
