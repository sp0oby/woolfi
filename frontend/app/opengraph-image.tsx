import {ImageResponse} from "next/og";

export const runtime = "edge";
export const alt = "WoolFi";
export const size = {width: 1200, height: 630};
export const contentType = "image/png";

/**
 * WoolFi OG image. A macro of two plied wool strands on the right, the logo and wordmark on the
 * dark left. No marketing copy - the link preview should feel like a name plate.
 *
 * Satori (Next.js OG runtime) doesn't have access to our Tailwind/Inter setup, so we draw the
 * logo as inline SVG and use the system mono fallback with wide letterspacing for the wordmark.
 * The background photo is bundled with the route, so there is no network fetch at request time.
 */
export default async function OG() {
  const bg = await fetch(new URL("../public/media/og-bg.jpg", import.meta.url)).then((r) => r.arrayBuffer());

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          background: "#0d0c0b",
          color: "#f5f1ea",
          display: "flex",
          position: "relative",
          fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element, jsx-a11y/alt-text */}
        <img
          src={bg as unknown as string}
          width={1200}
          height={630}
          style={{position: "absolute", inset: 0, width: 1200, height: 630}}
        />
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            paddingLeft: 96,
            gap: 28,
            height: "100%",
          }}
        >
          <svg width="96" height="96" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg">
            <path d="M8 6 C16 12, 16 20, 8 26" stroke="#f5f1ea" strokeWidth="2.75" fill="none" strokeLinecap="round" />
            <path d="M24 6 C16 12, 16 20, 24 26" stroke="#f5f1ea" strokeWidth="2.75" fill="none" strokeLinecap="round" />
            <path d="M8 6 C16 12, 16 20, 8 26" stroke="#8a7d65" strokeWidth="2.75" fill="none" strokeDasharray="0.7 1.5" opacity="0.5" />
            <path d="M24 6 C16 12, 16 20, 24 26" stroke="#8a7d65" strokeWidth="2.75" fill="none" strokeDasharray="0.7 1.5" strokeDashoffset="1" opacity="0.5" />
          </svg>
          <div style={{fontSize: 132, letterSpacing: "0.04em", fontWeight: 500, lineHeight: 1, display: "flex"}}>
            woolfi
          </div>
          <div style={{fontSize: 22, letterSpacing: "0.3em", color: "#eadbc0", display: "flex"}}>
            A MARKET FOR THE SPREAD
          </div>
        </div>
      </div>
    ),
    {...size},
  );
}
