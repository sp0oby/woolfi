// The splash wordmark, sewn on: a running stitch traces the letters, then the cream fill
// settles in and the stitch stays behind as a quiet seam inside the letterforms. CSS-only
// (see .stitch-* in globals.css), so it renders on the server and respects reduced motion.
export function StitchedWordmark({text = "woolfi."}: {text?: string}) {
  return (
    <h1 className="stitch-wordmark mt-8 w-full max-w-[980px] font-display">
      {/* Real text for crawlers and screen readers; the SVG below is the visual. */}
      <span className="sr-only">WoolFi - {text}</span>
      <svg viewBox="0 0 1000 260" className="h-auto w-full overflow-visible" aria-hidden>
        <defs>
          <linearGradient id="stitch-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#fffaf0" />
            <stop offset="55%" stopColor="#efe3c9" />
            <stop offset="100%" stopColor="#cdb88f" />
          </linearGradient>
          <mask id="stitch-reveal" maskUnits="userSpaceOnUse">
            <text x="500" y="205" textAnchor="middle" className="stitch-glyphs stitch-draw">
              {text}
            </text>
          </mask>
        </defs>
        <text x="500" y="205" textAnchor="middle" className="stitch-glyphs stitch-fill">
          {text}
        </text>
        <text
          x="500"
          y="205"
          textAnchor="middle"
          className="stitch-glyphs stitch-thread"
          mask="url(#stitch-reveal)"
        >
          {text}
        </text>
      </svg>
    </h1>
  );
}
