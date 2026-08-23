import type {Metadata} from "next";

import {Header} from "@/components/Header";
import {Footer} from "@/components/Footer";
import {WalletStatus} from "@/components/WalletStatus";
import {NetworkBanner} from "@/components/NetworkBanner";
import {DashboardHeading, DashboardTabs} from "@/components/DashboardMetadata";

export const metadata: Metadata = {
  title: "Dashboard",
  description:
    "WoolFi pool dashboard: drift band, market-hours state, recent swaps, rolling z-score, and trade, liquidity, and staking panels.",
};
import {PoolCard} from "@/components/PoolCard";
import {PoolPicker} from "@/components/PoolPicker";
import {MarketStatusBanner} from "@/components/MarketStatusBanner";
import {DisclosureModal} from "@/components/DisclosureModal";
import {RecentSwapsPanel} from "@/components/RecentSwapsPanel";
import {ZScoreChart} from "@/components/ZScoreChart";

export default function AppPage() {
  return (
    <main className="min-h-screen">
      <Header />
      <DisclosureModal />
      <article className="mx-auto max-w-2xl px-6 pt-24">
        <DashboardHeading />
        <PoolPicker />

        <NetworkBanner />
        <MarketStatusBanner />

        <PoolCard />

        <section className="mt-20">
          <DashboardTabs />
        </section>

        <ZScoreChart />
        <RecentSwapsPanel />

        <WalletStatus />
      </article>
      <Footer />
    </main>
  );
}

