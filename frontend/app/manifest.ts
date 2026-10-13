import type {MetadataRoute} from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "WoolFi - A market for the spread",
    short_name: "WoolFi",
    description: "Trade Robinhood stock tokens on Robinhood Chain with fees that reward keeping prices honest.",
    start_url: "/app",
    display: "standalone",
    background_color: "#0d0c0b",
    theme_color: "#0d0c0b",
    icons: [
      {src: "/icon.svg", sizes: "any", type: "image/svg+xml"},
      {src: "/apple-icon", sizes: "180x180", type: "image/png"},
    ],
  };
}
