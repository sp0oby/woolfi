import type {Metadata, Viewport} from "next";
import "./globals.css";

import {Providers} from "@/components/Providers";

const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://woolfi.market";

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
  // Deliberately short - five terms that actually describe the thing. Stuffing keyword lists
  // makes Google rank you lower these days, not higher.
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
  themeColor: "#000000",
  colorScheme: "dark",
};

export default function RootLayout({children}: {children: React.ReactNode}) {
  return (
    <html lang="en">
      <body className="bg-bg text-ink font-sans antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
