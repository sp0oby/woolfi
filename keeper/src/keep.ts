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
