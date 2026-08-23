"use client";

import {WagmiProvider} from "wagmi";
import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {RainbowKitProvider, darkTheme} from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";
import {useState} from "react";

import {config} from "@/lib/wagmi";
import {SelectedPoolProvider} from "@/hooks/useSelectedPool";

/**
 * Client-side providers: wagmi (chain + connectors), react-query (cache), RainbowKit (wallet UI).
 * Themed to match the splash - no shadow / no glow / no rounded corners, just contrast.
 */
export function Providers({children}: {children: React.ReactNode}) {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          modalSize="compact"
          theme={darkTheme({
            accentColor: "#ededed",
            accentColorForeground: "#0a0a0a",
            borderRadius: "none",
            fontStack: "system",
            overlayBlur: "small",
          })}
        >
          <SelectedPoolProvider>{children}</SelectedPoolProvider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
