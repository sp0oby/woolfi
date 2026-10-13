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

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  distDir: process.env.NEXT_DIST_DIR ?? ".next",
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
