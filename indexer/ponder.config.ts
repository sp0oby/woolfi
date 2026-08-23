import {createConfig} from "ponder";

import {woolfiHookAbi, woolfiPositionManagerAbi, woolfiUnderwritingVaultAbi} from "./abis";
import {vaultPools} from "./vaults";

/**
 * Ponder configuration for the WoolFi indexer.
 *
 * Robinhood contract addresses and the start block remain env-driven so one image can follow
 * successive production deployments without code changes.
 */
const chain = "robinhood" as const;

// Realtime poll cadence (ms). Higher = fewer RPC calls once the historical backfill has caught up.
const pollingInterval = Number(process.env.PONDER_POLLING_INTERVAL_MS ?? 2_000);

export default createConfig({
  chains: {
    robinhood: {
      id: 4663,
      rpc:
        process.env.PONDER_RPC_URL_ROBINHOOD ??
        "https://rpc.mainnet.chain.robinhood.com",
      pollingInterval,
    },
  },
  contracts: {
    WoolFiHook: {
      chain,
      abi: woolfiHookAbi,
      address: (process.env.PONDER_HOOK_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
      startBlock: Number(process.env.PONDER_START_BLOCK ?? 0),
    },
    WoolFiPositionManager: {
      chain,
      abi: woolfiPositionManagerAbi,
      address: (process.env.PONDER_PM_ADDRESS ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
      startBlock: Number(process.env.PONDER_START_BLOCK ?? 0),
    },
    WoolFiUnderwritingVault: {
      chain,
      abi: woolfiUnderwritingVaultAbi,
      address: vaultPools.map(({vault}) => vault),
      startBlock: Number(process.env.PONDER_START_BLOCK ?? 0),
    },
  },
});
