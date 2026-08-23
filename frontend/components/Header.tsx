import Link from "next/link";

import {WalletButton} from "@/components/WalletButton";

export function Header() {
  return (
    <header className="mx-auto max-w-2xl px-6 pt-10 flex items-baseline justify-between">
      <Link href="/" className="font-mono text-sm tracking-tight">
        WOOLFI <span className="text-[10px] text-muted">by Urufu Labs</span>
      </Link>
      <nav className="flex items-baseline gap-4 font-mono text-xs uppercase tracking-[0.18em] text-muted">
        <Link href="/app" className="hover:text-ink transition-colors">
          App
        </Link>
        <span aria-hidden className="text-line">·</span>
        <Link href="/docs" className="hover:text-ink transition-colors">
          Docs
        </Link>
        <span aria-hidden className="text-line">·</span>
        <Link href="/governance" className="hover:text-ink transition-colors">
          Gov
        </Link>
        <span aria-hidden className="text-line">·</span>
        <WalletButton />
      </nav>
    </header>
  );
}
