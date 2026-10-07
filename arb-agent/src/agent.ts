import type {Address, AgentConfig, ArbPool} from "./config.js";
import {type ChainReader, type ChainWriter, type PoolLog, scanPool} from "./scan.js";

/** One pass over every live pool. Per-pool failures are logged and never stop the tick. */
export async function runTick(
  chain: ChainReader,
  writer: ChainWriter | undefined,
  pools: ArbPool[],
  cfg: AgentConfig,
  sender: Address,
): Promise<PoolLog[]> {
  const logs: PoolLog[] = [];
  for (const pool of pools) {
    try {
      logs.push(await scanPool(chain, cfg.broadcast ? writer : undefined, pool, cfg, sender));
    } catch (error) {
      logs.push({slug: pool.slug, driftBps: "?", action: "error", error: error instanceof Error ? error.message : String(error)});
    }
  }
  return logs;
}
