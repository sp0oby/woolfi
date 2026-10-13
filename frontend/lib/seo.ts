import type {Metadata} from "next";

/**
 * Absolute origin used for canonical tags, Open Graph URLs, the sitemap and robots. There is no
 * production domain yet: set NEXT_PUBLIC_SITE_URL once there is one. Until then a Vercel
 * deployment uses its own production URL, and local builds fall back to localhost.
 */
export const SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL ??
  (process.env.VERCEL_PROJECT_PRODUCTION_URL
    ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
    : "http://localhost:3000");
export const SITE_NAME = "WoolFi";
export const X_HANDLE = "@urugemu";
export const X_URL = "https://x.com/urugemu";
export const GITHUB_URL = "https://github.com/urufu-labs/woolfi";
const OG_ALT = "WoolFi - a market for the spread on Robinhood Chain";

/**
 * Per-page metadata. Each page needs its own canonical URL and its own Open Graph / Twitter
 * title and description; without this, child routes inherit the root's and every link preview
 * (and every canonical tag) points at the splash. Images come from the opengraph-image files.
 */
export function pageMetadata({
  title,
  description,
  path,
}: {
  title: string;
  description: string;
  path: string;
}): Metadata {
  const fullTitle = `${title} - ${SITE_NAME}`;
  // Setting openGraph here replaces the parent's, so the site-wide card (app/opengraph-image.jpg)
  // has to be named again or subpages preview without an image.
  const images = [{url: "/opengraph-image.jpg", width: 1200, height: 630, alt: OG_ALT}];
  return {
    title,
    description,
    alternates: {canonical: path},
    openGraph: {
      type: "website",
      locale: "en_US",
      siteName: SITE_NAME,
      url: path,
      title: fullTitle,
      description,
      images,
    },
    twitter: {
      card: "summary_large_image",
      site: X_HANDLE,
      creator: X_HANDLE,
      title: fullTitle,
      description,
      images,
    },
  };
}
