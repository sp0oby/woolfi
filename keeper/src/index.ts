import {resolve} from "node:path";

import {createPublicClient, createWalletClient, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";

import {keepPools} from "./keep.js";
import {isDeployed, loadManifest} from "./manifest.js";

const ZERO = "0x0000000000000000000000000000000000000000";

async function main() {
  const manifestPath = process.env.KEEPER_MANIFEST ?? resolve("../frontend/lib/deployments/robinhood.json");
  const rpcUrl = process.env.ROBINHOOD_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
  const cadenceMs = Number(process.env.KEEPER_CADENCE_MS ?? 60_000);
  const broadcast = process.env.KEEPER_BROADCAST === "true";
  const keeper = optionalAddress(process.env.KEEPER_ADDRESS);
  const manifest = loadManifest(manifestPath);

  if (manifest.chainId !== 4663) {
    throw new Error(`keeper refuses chain ${manifest.chainId}`);
  }
  if (!isDeployed(manifest)) {
    console.log(JSON.stringify({ready: false, reason: "no live pools in manifest"}));
    return;
  }

  const publicClient = createPublicClient({transport: http(rpcUrl)});
  const walletClient =
    broadcast && process.env.KEEPER_PRIVATE_KEY
      ? createWalletClient({
          account: privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY as `0x${string}`),
          transport: http(rpcUrl),
        })
      : undefined;

  if (broadcast && !walletClient) {
    throw new Error("KEEPER_BROADCAST=true requires KEEPER_PRIVATE_KEY");
  }

  const run = async () => {
    const outcomes = await keepPools(
      {
        publicClient: {
          simulateContract: (args) => publicClient.simulateContract(args as never),
        },
        walletClient: walletClient
          ? {writeContract: (args) => walletClient.writeContract(args as never)}
          : undefined,
      },
      manifest.pools,
      {keeper, broadcast},
    );
    console.log(JSON.stringify({at: new Date().toISOString(), dryRun: !broadcast, outcomes}, null, 2));
  };

  await run();
  if (cadenceMs > 0) {
    setInterval(() => {
      void run();
    }, cadenceMs);
  }
}

function optionalAddress(value: string | undefined): `0x${string}` | undefined {
  if (!value || value.toLowerCase() === ZERO) return undefined;
  return value as `0x${string}`;
}

void main();
