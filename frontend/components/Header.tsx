"use client";

import Link from "next/link";
import {usePathname} from "next/navigation";

import {WalletButton} from "@/components/WalletButton";

export function Header() {
  const pathname = usePathname() ?? "/";
  const navCls = (href: string) =>
    `transition-colors ${pathname.startsWith(href) ? "text-ink" : "hover:text-ink"}`;
  return (
    <header className="look-header flex h-14 items-center justify-between border-b border-line bg-bg px-5">
      <Link href="/" className="flex items-baseline gap-2">
        <span className="font-display text-[26px] font-semibold leading-none tracking-tight text-ink">
          woolfi
        </span>
        <span className="font-mono text-micro uppercase tracking-[0.22em] text-subtle">
          by Urufu Labs
        </span>
      </Link>
      <nav className="flex items-center gap-6 font-mono text-2xs uppercase tracking-[0.22em] text-muted">
        <Link href="/app" className={navCls("/app")} aria-current={pathname.startsWith("/app") ? "page" : undefined}>
          Terminal
        </Link>
        <Link href="/docs" className={navCls("/docs")} aria-current={pathname.startsWith("/docs") ? "page" : undefined}>
          Docs
        </Link>
        <Link href="/governance" className={navCls("/governance")} aria-current={pathname.startsWith("/governance") ? "page" : undefined}>
          Gov
        </Link>
        <WalletButton />
      </nav>
    </header>
  );
}
