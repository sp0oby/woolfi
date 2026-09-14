import type {Config} from "tailwindcss";

export default {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // Slightly warmer near-black, hint of taupe for the "wool" feel.
        bg: "#0d0c0b",
        panel: "#171613",
        surface: "#1e1c19",
        ink: "#efe9dc",
        muted: "#8f887a",
        subtle: "#5e5850",
        line: "#2a2723",
        "line-strong": "#3a352e",

        // Interactive / CTA color: warm cream. Reads like natural wool on dark, not amber.
        signal: "#eadbc0",
        "signal-dim": "#8a7d65",

        // Semantic pair.
        pos: "#7fcf9f",
        "pos-dim": "#274f39",
        neg: "#e88c8c",
        "neg-dim": "#5c2828",

        // Warning / degraded states (kept warm amber, distinct from signal now).
        warn: "#e0a848",
        // Break / paused states.
        danger: "#e26060",
      },
      fontFamily: {
        display: ["var(--font-display)", "ui-sans-serif", "system-ui", "sans-serif"],
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "SFMono-Regular", "monospace"],
      },
      fontSize: {
        micro: ["10px", {lineHeight: "1.2"}],
        "2xs": ["11px", {lineHeight: "1.3"}],
      },
      borderRadius: {
        // Subtle 2px rounding across the board — softens the "flat rectangle" feel without
        // going soft-app on us.
        DEFAULT: "2px",
        sm: "2px",
        md: "3px",
        lg: "4px",
      },
      boxShadow: {
        // Card elevation: inset top-highlight for a rim-lit feel + soft outer depth.
        card: "inset 0 1px 0 rgba(255, 245, 220, 0.04), 0 1px 2px rgba(0, 0, 0, 0.4), 0 8px 24px rgba(0, 0, 0, 0.28)",
        // Softer variant for smaller components.
        raised: "inset 0 1px 0 rgba(255, 245, 220, 0.03), 0 1px 3px rgba(0, 0, 0, 0.4)",
        // Focus / signal glow on CTAs.
        signal: "0 0 0 1px rgba(234, 219, 192, 0.4), 0 6px 18px rgba(234, 219, 192, 0.08)",
      },
      keyframes: {
        pulse: {
          "0%, 100%": {opacity: "1", transform: "scale(1)"},
          "50%": {opacity: "0.4", transform: "scale(0.85)"},
        },
        tickerScroll: {
          "0%": {transform: "translateX(0)"},
          "100%": {transform: "translateX(-50%)"},
        },
      },
      animation: {
        "signal-pulse": "pulse 1.8s ease-in-out infinite",
        ticker: "tickerScroll 60s linear infinite",
      },
    },
  },
} satisfies Config;
