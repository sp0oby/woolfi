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
