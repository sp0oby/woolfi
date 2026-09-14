import Link from "next/link";

import {WalletButton} from "@/components/WalletButton";

export function Header() {
  return (
    <header className="flex h-14 items-center justify-between border-b border-line bg-bg px-5">
      <Link href="/" className="flex items-baseline gap-2">
        <span className="font-display text-[26px] font-semibold leading-none tracking-tight text-ink">
          woolfi
        </span>
        <span className="font-mono text-micro uppercase tracking-[0.22em] text-subtle">
          by Urufu Labs
        </span>
      </Link>
      <nav className="flex items-center gap-6 font-mono text-2xs uppercase tracking-[0.22em] text-muted">
        <Link href="/app" className="text-ink transition-colors hover:text-signal">
          Terminal
        </Link>
        <Link href="/docs" className="transition-colors hover:text-ink">
          Docs
        </Link>
        <Link href="/governance" className="transition-colors hover:text-ink">
          Gov
        </Link>
        <WalletButton />
      </nav>
    </header>
  );
}
