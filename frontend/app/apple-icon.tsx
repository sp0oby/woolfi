import {ImageResponse} from "next/og";

export const size = {width: 180, height: 180};
export const contentType = "image/png";

// Home-screen and iMessage icon: the plied-strand mark on the page background, full bleed
// (iOS rounds the corners itself).
export default function AppleIcon() {
  return new ImageResponse(
    (
      <div style={{width: "100%", height: "100%", background: "#0d0c0b", display: "flex", alignItems: "center", justifyContent: "center"}}>
        <svg width="132" height="132" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg">
          <path d="M8 6 C16 12, 16 20, 8 26" stroke="#f5f1ea" strokeWidth="2.75" fill="none" strokeLinecap="round" />
          <path d="M24 6 C16 12, 16 20, 24 26" stroke="#f5f1ea" strokeWidth="2.75" fill="none" strokeLinecap="round" />
          <path d="M8 6 C16 12, 16 20, 8 26" stroke="#8a7d65" strokeWidth="2.75" fill="none" strokeDasharray="0.7 1.5" opacity="0.5" />
          <path d="M24 6 C16 12, 16 20, 24 26" stroke="#8a7d65" strokeWidth="2.75" fill="none" strokeDasharray="0.7 1.5" strokeDashoffset="1" opacity="0.5" />
        </svg>
      </div>
    ),
    {...size},
  );
}
