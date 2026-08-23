import {http} from "wagmi";
import {getDefaultConfig} from "@rainbow-me/rainbowkit";
import {defineChain} from "viem";

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {
    default: {http: ["https://rpc.mainnet.chain.robinhood.com"]},
  },
  blockExplorers: {
    default: {name: "Blockscout", url: "https://robinhoodchain.blockscout.com"},
  },
});

export type ConfiguredChainId = typeof robinhood.id;

/**
 * WalletConnect project id (from cloud.walletconnect.com). Optional - RainbowKit still works
 * with injected/browser wallets if this isn't set, just without WC modal support.
 */
const projectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "woolfi-dev";

const robinhoodRpc = process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL;

export const config = getDefaultConfig({
  appName: "WoolFi",
  projectId,
  chains: [robinhood],
  transports: {
    [robinhood.id]: http(robinhoodRpc),
  },
  ssr: true,
});

export const chainNameById: Record<number, string> = {
  [robinhood.id]: "Robinhood Chain",
};

const explorerById: Record<number, string> = {
  [robinhood.id]: "https://robinhoodchain.blockscout.com",
};

export function explorerTx(chainId: number | undefined, hash: `0x${string}`): string | undefined {
  const base = chainId !== undefined ? explorerById[chainId] : undefined;
  return base ? `${base}/tx/${hash}` : undefined;
}

export function explorerAddress(chainId: number | undefined, addr: `0x${string}`): string | undefined {
  const base = chainId !== undefined ? explorerById[chainId] : undefined;
  return base ? `${base}/address/${addr}` : undefined;
}
