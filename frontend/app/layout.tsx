import type {Metadata, Viewport} from "next";
import {Fredoka, Inter, IBM_Plex_Mono} from "next/font/google";

import "./globals.css";

import {Providers} from "@/components/Providers";
import {SITE_NAME, SITE_URL, X_HANDLE} from "@/lib/seo";

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
  "Trade Robinhood stock tokens on Robinhood Chain with fees that reward keeping prices honest. A Uniswap v4 market of 18 pools, with liquidity providers earning fees and URU underwriting each pool.";
const TITLE = "WoolFi - A market for the spread";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  applicationName: SITE_NAME,
  title: {
    default: TITLE,
    template: `%s - ${SITE_NAME}`,
  },
  description: DESCRIPTION,
  keywords: [
    "WoolFi",
    "Urufu Labs",
    "Urufu Gemu",
    "Uniswap v4 hook",
    "Robinhood Chain",
    "Robinhood Stock Tokens",
    "tokenized stocks",
    "DeFi",
    "AMM",
    "spread trading",
    "URU",
    "WETH",
    "USDG",
  ],
  authors: [{name: "Urufu Labs"}],
  creator: "Urufu Labs",
  publisher: "Urufu Labs",
  category: "finance",
  // Home only: every other page sets its own canonical through pageMetadata().
  alternates: {canonical: "/"},
  openGraph: {
    type: "website",
    locale: "en_US",
    url: "/",
    siteName: SITE_NAME,
    title: TITLE,
    description: DESCRIPTION,
  },
  twitter: {
    card: "summary_large_image",
    site: X_HANDLE,
    creator: X_HANDLE,
    title: TITLE,
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
};

export const viewport: Viewport = {
  themeColor: "#0d0c0b",
  colorScheme: "dark",
};

// Development only: `?ack=1` pre-acknowledges the disclosure and `?notour=1` suppresses the tour,
// so headless screenshots of /app are not covered by overlays. Empty in production builds.
const DEV_SCRIPT =
  process.env.NODE_ENV !== "production"
    ? `(function(){try{var q=new URLSearchParams(location.search);if(q.has("ack"))localStorage.setItem("woolfi.disclosure.ack.v3",new Date().toISOString());if(q.has("notour"))window.__woolfiNoTour=true;}catch(e){}})();`
    : "";

export default function RootLayout({children}: {children: React.ReactNode}) {
  return (
    <html
      lang="en"
      className={`${display.variable} ${sans.variable} ${mono.variable}`}
      suppressHydrationWarning
    >
      {DEV_SCRIPT ? (
        <head>
          <script dangerouslySetInnerHTML={{__html: DEV_SCRIPT}} />
        </head>
      ) : null}
      <body className="bg-bg text-ink font-sans antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
