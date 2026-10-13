import type {Metadata} from "next";

import {DisclosureModal} from "@/components/DisclosureModal";
import {Header} from "@/components/Header";
import {NetworkBanner} from "@/components/NetworkBanner";
import {TerminalShell} from "@/components/terminal/TerminalShell";
import {pageMetadata} from "@/lib/seo";

export const metadata: Metadata = pageMetadata({
  title: "Terminal",
  description:
    "Trade Robinhood stock tokens, provide liquidity, and underwrite pools with URU across WoolFi's 18-pool market on Robinhood Chain.",
  path: "/app",
});

export default function AppPage() {
  return (
    <main className="min-h-screen">
      <Header />
      <DisclosureModal />
      <NetworkBanner />
      <TerminalShell />
    </main>
  );
}
