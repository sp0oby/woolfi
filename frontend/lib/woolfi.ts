import robinhood from "./deployments/robinhood.json";
import type {CuratedPool, DeployedPool} from "./pools/types";

export type DeploymentConfig = {
  chainId: number;
  poolManager: `0x${string}`;
  hook: `0x${string}`;
  positionManager: `0x${string}`;
  governor: `0x${string}`;
  stakingToken: `0x${string}`;
  stakingSymbol: string;
  swapRouter?: `0x${string}`;
  pools: readonly DeployedPool[];
};

export type WoolFiDeployment = DeploymentConfig & DeployedPool;

const ZERO = "0x0000000000000000000000000000000000000000" as const;

const raw = robinhood as Omit<DeploymentConfig, "swapRouter" | "pools"> & {
  swapRouter?: `0x${string}`;
  pools?: readonly DeployedPool[];
};

export const robinhoodDeployment: DeploymentConfig = {
  ...raw,
  swapRouter: nonZero(raw.swapRouter),
  stakingSymbol: "URU",
  pools: raw.pools ?? [],
};

export const deploymentConfigs: Record<number, DeploymentConfig> = {
  [robinhoodDeployment.chainId]: robinhoodDeployment,
};

export const preferredDeploymentChainId = robinhoodDeployment.chainId;

export function getDeploymentConfig(chainId: number | undefined): DeploymentConfig | null {
  return chainId === robinhoodDeployment.chainId ? robinhoodDeployment : null;
}

export function deploymentForPool(
  chainId: number | undefined,
  pool: CuratedPool,
): WoolFiDeployment | null {
  const config = getDeploymentConfig(chainId);
  if (!config || !isProtocolDeployed(config) || pool.status !== "live" || !pool.deployment) return null;
  return {...config, ...pool.deployment};
}

function isProtocolDeployed(config: DeploymentConfig): boolean {
  return (
    config.hook !== ZERO &&
    config.positionManager !== ZERO &&
    config.stakingToken !== ZERO &&
    config.poolManager !== ZERO
  );
}

function nonZero(address: `0x${string}` | undefined): `0x${string}` | undefined {
  return address && address !== ZERO ? address : undefined;
}

export function shortAddr(addr: string): string {
  if (!addr || addr.length < 10) return addr ?? "-";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}
