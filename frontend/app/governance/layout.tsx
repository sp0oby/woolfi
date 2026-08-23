import type {Metadata} from "next";

// Governance page is a client component (live multisig owner read), so we attach metadata
// here via a wrapping layout - the only way the App Router exposes <title>/<meta> for a
// 'use client' route.
export const metadata: Metadata = {
  title: "Governance",
  description:
    "How WoolFi's v1 multisig administers pools on Robinhood Chain, and what it cannot change.",
};

export default function GovernanceLayout({children}: {children: React.ReactNode}) {
  return children;
}
