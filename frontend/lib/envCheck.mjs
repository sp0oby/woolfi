/**
 * Production settings a public build needs. Missing any of them breaks something users see:
 * phone wallets (WalletConnect QR), swap history (indexer), or link previews and canonical URLs.
 *
 * Returns the problems found. `next.config.mjs` warns about them on every production build and
 * fails the build once the deployment manifest says the launch is live.
 *
 * @param {Record<string, string | undefined>} env
 * @returns {string[]}
 */
export function productionEnvProblems(env) {
  const problems = [];
  const wc = env.NEXT_PUBLIC_WC_PROJECT_ID;
  if (!wc || wc === "woolfi-dev") {
    problems.push("NEXT_PUBLIC_WC_PROJECT_ID is unset: phone wallets cannot connect by QR code.");
  }
  const indexer = env.NEXT_PUBLIC_INDEXER_URL;
  if (!indexer || /localhost|127\.0\.0\.1/.test(indexer)) {
    problems.push("NEXT_PUBLIC_INDEXER_URL is unset or local: swap history will not load.");
  }
  const site = env.NEXT_PUBLIC_SITE_URL;
  if (!site && !env.VERCEL_PROJECT_PRODUCTION_URL) {
    problems.push("NEXT_PUBLIC_SITE_URL is unset: link previews, canonical URLs and the sitemap point at localhost.");
  }
  return problems;
}
