"use client";

import {useChainId} from "wagmi";

import {Header} from "@/components/Header";
import {Footer} from "@/components/Footer";
import {explorerAddress} from "@/lib/wagmi";

// Displayed as the protocol multisig. On testnet the on-chain owner of WoolFiGovernor is the
// deployer EOA (iteration mode); this is the address that owns it on mainnet from genesis and
// the one we want partners to see on /governance. Update when the mainnet Safe is finalized.
const MULTISIG_ADDRESS = "0x935B53040Bf112A9E93297Ac9603b5BA9F0c7Aa0" as const;

export default function GovernancePage() {
  const chainId = useChainId();

  return (
    <main className="min-h-screen">
      <Header />
      <article className="mx-auto max-w-2xl px-6 pt-24 pb-32">
        <p className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">Governance</p>
        <h1 className="mt-3 text-[36px] sm:text-[44px] font-medium tracking-[-0.02em] leading-[1.1]">
          Who decides what.
        </h1>
        <p className="mt-8 text-[17px] leading-relaxed text-ink/85">
          WoolFi v1 is administered by a multisig on Robinhood Chain. There is no token-holder voting
          in v1.
        </p>

        <Section label="Today">
          <p>
            A multisig controls the protocol's admin surface. The signers can authorize new pools,
            re-tune live pool parameters, pause the hook in an emergency, and resolve a structural
            break once the underlying market has reconverged. The multisig <em>cannot</em> seize
            user funds, alter LP balances, or change vault staker positions - those rules are
            enforced by the contracts themselves.
          </p>
          <Address label="Multisig" address={MULTISIG_ADDRESS} chainId={chainId} />
        </Section>

        <Section label="Underwriting is separate">
          <p>
            URU is the asset deposited into per-pool underwriting vaults. It bears configured
            structural-break risk and may receive configured pool fees. Holding or staking URU
            does not grant protocol voting rights in v1.
          </p>
        </Section>

        <Section label="Voting">
          <div className="border border-line bg-white/[0.02] px-6 py-10 text-center">
            <p className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">
              v1 administration
            </p>
            <p className="mt-3 text-[15px] text-ink/85">
              Multisig controlled. No token vote is active.
            </p>
          </div>
        </Section>

        <Section label="What can't change, ever">
          <ul className="space-y-2 text-[15px] text-ink/85 list-disc pl-5 marker:text-muted">
            <li>WoolFi never custodies user assets - they live in Uniswap v4's PoolManager and the per-pool vault contract.</li>
            <li>Governance cannot move LP positions or vault stakes between accounts.</li>
            <li>WoolFi cannot issue Robinhood Stock Tokens; their issuer controls issuance and applicable transfer restrictions.</li>
            <li>The asymmetric-fee mechanic and the structural-break drawdown rules are coded into the hook; the multisig can pause them, not rewrite them.</li>
          </ul>
        </Section>
      </article>
      <Footer />
    </main>
  );
}

function Section({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <section className="mt-16">
      <h2 className="font-mono text-[11px] uppercase tracking-[0.22em] text-muted">{label}</h2>
      <div className="mt-4 space-y-4 text-[15px] leading-[1.75] text-ink/85">{children}</div>
    </section>
  );
}

function Address({
  label,
  address,
  chainId,
}: {
  label: string;
  address: `0x${string}` | undefined;
  chainId: number;
}) {
  const url = address ? explorerAddress(chainId, address) : undefined;
  return (
    <div className="mt-4 flex items-baseline justify-between border-t border-line pt-3 font-mono text-[12px]">
      <span className="uppercase tracking-[0.18em] text-muted">{label}</span>
      {address ? (
        url ? (
          <a href={url} target="_blank" rel="noreferrer" className="text-white hover:underline break-all">
            {address} ↗
          </a>
        ) : (
          <span className="text-white break-all">{address}</span>
        )
      ) : (
        <span className="text-muted">-</span>
      )}
    </div>
  );
}
