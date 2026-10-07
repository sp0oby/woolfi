import {createPublicClient, createWalletClient, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";

import {runTick} from "./agent.js";
import {type Address, loadConfig, loadPools} from "./config.js";
import {explain} from "./explain.js";
import type {PoolLog} from "./scan.js";

const DRY_RUN_SENDER = "0x000000000000000000000000000000000000dEaD" as Address;

async function main() {
  const cfg = loadConfig();
  const {chainId, pools} = loadPools(cfg.manifestPath);
  if (chainId !== 4663) throw new Error(`arb-agent refuses chain ${chainId}`);
  if (pools.length === 0) {
    console.log(JSON.stringify({ready: false, reason: "no live pools in manifest (launchStatus must be live)"}));
    return;
  }

  const publicClient = createPublicClient({transport: http(cfg.rpcUrl)});
  const account = cfg.privateKey ? privateKeyToAccount(cfg.privateKey) : undefined;
  const walletClient = cfg.broadcast && account ? createWalletClient({account, transport: http(cfg.rpcUrl)}) : undefined;
  const sender = account?.address ?? DRY_RUN_SENDER;

  const chain = {
    readContract: (a: Record<string, unknown>) => publicClient.readContract(a as never),
    simulateContract: (a: Record<string, unknown>) => publicClient.simulateContract(a as never) as never,
    estimateContractGas: (a: Record<string, unknown>) => publicClient.estimateContractGas(a as never),
    getGasPrice: () => publicClient.getGasPrice(),
  };
  const writer = walletClient ? {writeContract: (r: Record<string, unknown>) => walletClient.writeContract(r as never)} : undefined;

  const recent: PoolLog[] = [];
  let tick = 0;
  const loop = async () => {
    tick += 1;
    const logs = await runTick(chain, writer, pools, cfg, sender);
    for (const l of logs) console.log(JSON.stringify({at: new Date().toISOString(), dryRun: !cfg.broadcast, ...l}));
    recent.push(...logs);
    if (recent.length > 200) recent.splice(0, recent.length - 200);
    const traded = logs.some((l) => l.action === "executed");
    if (traded || tick % cfg.explainEveryTicks === 0) {
      void explain(recent, {apiKey: cfg.anthropicApiKey, webhook: cfg.reportWebhook});
    }
  };

  await loop();
  setInterval(() => void loop().catch((e) => console.error(JSON.stringify({tickError: String(e)}))), cfg.cadenceMs);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
