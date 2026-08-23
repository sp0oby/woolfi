import {ImageResponse} from "next/og";

export const runtime = "edge";
export const alt = "WoolFi";
export const size = {width: 1200, height: 630};
export const contentType = "image/png";

/**
 * WoolFi OG image. Black canvas, the logo on the left, the wordmark on the right, the URL in
 * tiny mono at the bottom. No marketing copy - the link preview should feel like a name plate.
 *
 * Satori (Next.js OG runtime) doesn't have access to our Tailwind/Inter setup, so we draw the
 * logo as inline SVG and use the system mono fallback with wide letterspacing for the wordmark.
 * Keeping this self-contained means no font-fetching latency at request time.
 */
export default async function OG() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          background: "#000",
          color: "#f5f1ea",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 44,
          fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        }}
      >
        <svg width="170" height="170" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg">
          <path d="M8 6 C16 12, 16 20, 8 26" stroke="#f5f1ea" strokeWidth="2.25" fill="none" strokeLinecap="round" />
          <path d="M24 6 C16 12, 16 20, 24 26" stroke="#f5f1ea" strokeWidth="2.25" fill="none" strokeLinecap="round" />
        </svg>
        <div
          style={{
            fontSize: 180,
            letterSpacing: "0.06em",
            fontWeight: 500,
            lineHeight: 1,
            display: "flex",
          }}
        >
          woolfi
        </div>
      </div>
    ),
    {...size},
  );
}
