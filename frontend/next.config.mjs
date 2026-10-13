import {readFileSync} from "node:fs";

import {productionEnvProblems} from "./lib/envCheck.mjs";

// Production-settings check (see lib/envCheck.mjs). Pre-launch builds only warn; once the
// manifest is live, a public build with missing settings fails instead of shipping broken.
if (process.env.NODE_ENV === "production") {
  const problems = productionEnvProblems(process.env);
  if (problems.length) {
    const manifest = JSON.parse(readFileSync(new URL("./lib/deployments/robinhood.json", import.meta.url), "utf8"));
    const message = `Production settings:\n  - ${problems.join("\n  - ")}`;
    if (manifest.launchStatus === "live") throw new Error(message);
    console.warn(`warning: ${message}`);
  }
}

/** Origin of an optional URL setting, or nothing if unset/malformed (never breaks the build). */
function originOf(value) {
  if (!value) return [];
  try {
    return [new URL(value).origin];
  } catch {
    return [];
  }
}

const isDev = process.env.NODE_ENV !== "production";

// Content-Security-Policy. Next inlines its bootstrap scripts, so script-src needs
// 'unsafe-inline'; 'unsafe-eval' is only for dev (react-refresh). connect-src covers the chain
// RPC, the indexer and WalletConnect/Reown relays; frame-src covers WalletConnect verify/secure.
const csp = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' https://fonts.gstatic.com data:",
  "img-src 'self' data: blob: https:",
  "media-src 'self'",
  [
    "connect-src 'self'",
    "https://rpc.mainnet.chain.robinhood.com",
    ...originOf(process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL),
    ...originOf(process.env.NEXT_PUBLIC_INDEXER_URL),
    // Local indexer default (lib/indexer/client.ts) when NEXT_PUBLIC_INDEXER_URL is unset in dev.
    ...(isDev && !process.env.NEXT_PUBLIC_INDEXER_URL ? ["http://localhost:42069"] : []),
    // Dev server hot-reload socket.
    ...(isDev ? ["ws:"] : []),
    "https://*.walletconnect.com",
    "https://*.walletconnect.org",
    "wss://*.walletconnect.com",
    "wss://*.walletconnect.org",
    "https://*.reown.com",
    "wss://*.reown.com",
    "https://explorer-api.walletconnect.com",
    // WalletConnect's AppKit fetches its remote project config from here on init.
    "https://*.web3modal.org",
    "https://*.web3modal.com",
  ].join(" "),
  "frame-src https://verify.walletconnect.com https://verify.walletconnect.org https://secure.walletconnect.org",
  "frame-ancestors 'none'",
].join("; ");

const securityHeaders = [
  {key: "Content-Security-Policy", value: csp},
  {key: "X-Frame-Options", value: "DENY"},
  {key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains"},
  {key: "Referrer-Policy", value: "strict-origin-when-cross-origin"},
  {key: "X-Content-Type-Options", value: "nosniff"},
  {key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()"},
];

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  distDir: process.env.NEXT_DIST_DIR ?? ".next",
  async headers() {
    return [{source: "/:path*", headers: securityHeaders}];
  },
  webpack: (config, { dev }) => {
    // wagmi/RainbowKit pull in optional React-Native and node-only peers that aren't needed
    // in the browser. Alias them to false so webpack stops looking.
    config.resolve.alias = {
      ...config.resolve.alias,
      "@react-native-async-storage/async-storage": false,
      "pino-pretty": false,
    };
    // macOS caps open files per process (kern.maxfilesperproc=10240). The dep tree here is
    // large enough that watching node_modules exhausts that limit (EMFILE). Skip watching it.
    if (dev) {
      config.watchOptions = {
        ...config.watchOptions,
        ignored: ["**/node_modules/**", "**/.next/**", "**/.git/**"],
      };
    }
    return config;
  },
};

export default nextConfig;
