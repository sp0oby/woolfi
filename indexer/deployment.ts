import manifestJson from "../frontend/lib/deployments/robinhood.json";

const ZERO = "0x0000000000000000000000000000000000000000" as const;

type Manifest = {
  launchStatus?: string;
  hook?: string;
  positionManager?: string;
  rebateDistributor?: string;
  startBlocks?: Record<string, number>;
  pools?: Array<{poolId?: string; vault?: string; startBlock?: number}>;
};

export const deployment = manifestJson as Manifest;

export function contractSource(
  field: "hook" | "positionManager" | "rebateDistributor",
  addressEnv: string | undefined,
  startEnv: string | undefined,
) {
  const manifestAddress = deployment[field] ?? ZERO;
  const manifestStart = deployment.startBlocks?.[field] ?? 0;
  const address = addressEnv ?? manifestAddress;
  const startBlock = Number(startEnv ?? manifestStart);
  if (deployment.launchStatus === "live") {
    if (address.toLowerCase() !== manifestAddress.toLowerCase()) {
      throw new Error(`${field} env address conflicts with live manifest`);
    }
    if (startBlock !== manifestStart || startBlock <= 0) {
      throw new Error(`${field} start block conflicts with live receipt-backed manifest`);
    }
  }
  return {address: address as `0x${string}`, startBlock};
}
