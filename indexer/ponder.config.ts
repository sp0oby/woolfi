import {createConfig} from "ponder";

import {
  urufuFeeRebateDistributorAbi,
  woolfiHookAbi,
  woolfiPositionManagerAbi,
  woolfiUnderwritingVaultAbi,
} from "./abis";
import {contractSource, deployment} from "./deployment";
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
const hook = contractSource("hook", process.env.PONDER_HOOK_ADDRESS, process.env.PONDER_HOOK_START_BLOCK ?? process.env.PONDER_START_BLOCK);
const positionManager = contractSource(
  "positionManager",
  process.env.PONDER_PM_ADDRESS,
  process.env.PONDER_PM_START_BLOCK ?? process.env.PONDER_START_BLOCK,
);
const rebateDistributor = contractSource(
  "rebateDistributor",
  process.env.PONDER_REBATE_ADDRESS,
  process.env.PONDER_REBATE_START_BLOCK ?? process.env.PONDER_START_BLOCK,
);
const vaultStartBlock = deployment.launchStatus === "live"
  ? Math.min(...(deployment.pools ?? []).map((pool) => pool.startBlock ?? 0))
  : Number(process.env.PONDER_VAULT_START_BLOCK ?? process.env.PONDER_START_BLOCK ?? 0);

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
      ...hook,
    },
    WoolFiPositionManager: {
      chain,
      abi: woolfiPositionManagerAbi,
      ...positionManager,
    },
    WoolFiUnderwritingVault: {
      chain,
      abi: woolfiUnderwritingVaultAbi,
      address: vaultPools.map(({vault}) => vault),
      startBlock: vaultStartBlock,
    },
    UrufuFeeRebateDistributor: {
      chain,
      abi: urufuFeeRebateDistributorAbi,
      ...rebateDistributor,
    },
  },
});
