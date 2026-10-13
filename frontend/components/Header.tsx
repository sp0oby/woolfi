"use client";

import Link from "next/link";
import {usePathname} from "next/navigation";

import {WalletButton} from "@/components/WalletButton";

export function Header() {
  const pathname = usePathname() ?? "/";
  const navCls = (href: string) =>
    `transition-colors ${pathname.startsWith(href) ? "text-ink" : "hover:text-ink"}`;
  return (
    <header className="look-header flex h-14 items-center justify-between gap-3 border-b border-line bg-bg px-4 sm:px-5">
      <Link href="/" className="flex shrink-0 items-baseline gap-2">
        <span className="font-display text-[24px] font-semibold leading-none tracking-tight text-ink sm:text-[26px]">
          woolfi
        </span>
        {/* The tagline would crowd the nav off a phone screen. */}
        <span className="hidden font-mono text-micro uppercase tracking-[0.22em] text-subtle sm:inline">
          by Urufu Labs
        </span>
      </Link>
      <nav className="flex min-w-0 items-center gap-4 font-mono text-2xs uppercase tracking-[0.14em] text-muted sm:gap-6 sm:tracking-[0.22em]">
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
