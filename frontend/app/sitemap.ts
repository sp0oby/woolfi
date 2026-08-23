import type {MetadataRoute} from "next";

const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://woolfi.market";

export default function sitemap(): MetadataRoute.Sitemap {
  const now = new Date();
  return [
    {url: `${SITE_URL}/`, lastModified: now, changeFrequency: "weekly", priority: 1},
    {url: `${SITE_URL}/app`, lastModified: now, changeFrequency: "daily", priority: 0.9},
    {url: `${SITE_URL}/docs`, lastModified: now, changeFrequency: "weekly", priority: 0.8},
  ];
}
