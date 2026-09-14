import type {Metadata} from "next";

import {DisclosureModal} from "@/components/DisclosureModal";
import {Header} from "@/components/Header";
import {NetworkBanner} from "@/components/NetworkBanner";
import {TerminalShell} from "@/components/terminal/TerminalShell";

export const metadata: Metadata = {
  title: "Terminal",
  description:
    "WoolFi trade terminal: 16-pool rail, live drift chart, recent swaps, and stacked trade / liquidity / stake actions on Robinhood Chain.",
};

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
