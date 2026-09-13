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
