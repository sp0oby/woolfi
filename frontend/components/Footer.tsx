export function Footer() {
  return (
    <footer className="mx-auto max-w-2xl px-6 pb-20 mt-32 pt-10 border-t border-line text-[13px] leading-relaxed text-muted">
      <p>
        Robinhood Stock Tokens provide economic exposure, not ownership of underlying securities.
        Issuer terms and geographic restrictions apply. Confirm eligibility before trading. WoolFi
        is unaudited; nothing here is investment advice.
      </p>
      <p className="mt-4">
        © WoolFi by Urufu Labs. Not affiliated with Robinhood, any token issuer, or Uniswap Labs.
      </p>
      <nav className="mt-6 flex flex-wrap items-baseline gap-x-5 gap-y-2 font-mono text-[11px] uppercase tracking-[0.18em] text-muted">
        <a
          href="https://github.com/urufu-labs/woolfi"
          target="_blank"
          rel="noreferrer"
          className="hover:text-ink transition-colors"
        >
          GitHub ↗
        </a>
        <a
          href="https://github.com/urufu-labs/woolfi/blob/main/PROJECT_SPEC.md"
          target="_blank"
          rel="noreferrer"
          className="hover:text-ink transition-colors"
        >
          Spec ↗
        </a>
      </nav>
    </footer>
  );
}
