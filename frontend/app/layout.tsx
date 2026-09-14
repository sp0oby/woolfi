import type {Metadata, Viewport} from "next";
import {Fredoka, Inter, IBM_Plex_Mono} from "next/font/google";

import "./globals.css";

import {Providers} from "@/components/Providers";

const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://woolfi.market";

// Fredoka - rounded, soft, "cotton/cloud" quality - used only for the WoolFi wordmark and
// occasional numeric hero moments. Everything else uses Inter (UI sans) or Plex Mono (numbers).
const display = Fredoka({
  subsets: ["latin"],
  weight: ["500", "600", "700"],
  variable: "--font-display",
  display: "swap",
});

const sans = Inter({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-sans",
  display: "swap",
});

const mono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-mono",
  display: "swap",
});

// One sentence, written like a human would tell you what this is. Reused across OG/Twitter so
// link previews on Slack, X, Telegram, etc. say the same thing the splash page says.
const DESCRIPTION =
  "A Uniswap v4 multi-pool market for Robinhood Stock Tokens, WETH, and USDG on Robinhood Chain, with URU per-pool underwriting.";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: "WoolFi - A market for the spread",
    template: "%s - WoolFi",
  },
  description: DESCRIPTION,
  keywords: ["Uniswap v4", "Robinhood Chain", "Robinhood Stock Tokens", "WETH", "USDG"],
  authors: [{name: "Urufu Labs"}],
  creator: "Urufu Labs",
  openGraph: {
    type: "website",
    locale: "en_US",
    url: SITE_URL,
    siteName: "WoolFi",
    title: "WoolFi - A market for the spread",
    description: DESCRIPTION,
  },
  twitter: {
    card: "summary_large_image",
    title: "WoolFi - A market for the spread",
    description: DESCRIPTION,
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
    },
  },
  alternates: {canonical: SITE_URL},
};

export const viewport: Viewport = {
  themeColor: "#0b0b0d",
  colorScheme: "dark",
};

export default function RootLayout({children}: {children: React.ReactNode}) {
  return (
    <html lang="en" className={`${display.variable} ${sans.variable} ${mono.variable}`}>
      <body className="bg-bg text-ink font-sans antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
