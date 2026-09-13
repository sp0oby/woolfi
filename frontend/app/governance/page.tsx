"use client";

import {useChainId, useReadContracts} from "wagmi";

import {Header} from "@/components/Header";
import {Footer} from "@/components/Footer";
import {explorerAddress} from "@/lib/wagmi";
import {robinhoodDeployment} from "@/lib/woolfi";

const ZERO = "0x0000000000000000000000000000000000000000";

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
            break once the underlying market has reconverged. It can also configure vault
            drawdowns and fee routing within contract limits, but cannot directly edit an
            account&apos;s LP-share or vault-share balance.
          </p>
          <GovernanceStatus chainId={chainId} />
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
              Multisig controlled. No token vote or browser-based admin console is active.
            </p>
          </div>
        </Section>

        <Section label="Contract boundaries">
          <ul className="space-y-2 text-[15px] text-ink/85 list-disc pl-5 marker:text-muted">
            <li>Pool assets settle through Uniswap v4&apos;s PoolManager; URU underwriting is held by per-pool vaults.</li>
            <li>Governance cannot directly move LP shares or vault shares between accounts.</li>
            <li>WoolFi cannot issue Robinhood Stock Tokens; their issuer controls issuance and applicable transfer restrictions.</li>
            <li>The hook&apos;s code is immutable after deployment, while its documented parameters and authorized pools remain multisig-configurable.</li>
          </ul>
        </Section>
      </article>
      <Footer />
    </main>
  );
}

function GovernanceStatus({chainId}: {chainId: number}) {
  const {governor, hook, positionManager} = robinhoodDeployment;
  const deployed = governor !== ZERO && hook !== ZERO && positionManager !== ZERO;
  if (!deployed) {
    return (
      <div className="mt-5 border border-line px-5 py-4 font-mono text-[12px] text-muted">
        Not deployed. No production governor or multisig owner is recorded in the manifest.
      </div>
    );
  }
  return (
    <LiveGovernance
      chainId={chainId}
      governor={governor}
      hook={hook}
      positionManager={positionManager}
    />
  );
}

const ownerAbi = [{
  type: "function",
  name: "owner",
  stateMutability: "view",
  inputs: [],
  outputs: [{name: "", type: "address"}],
}] as const;

const governorAbi = [{
  type: "function",
  name: "hook",
  stateMutability: "view",
  inputs: [],
  outputs: [{name: "", type: "address"}],
}] as const;

const hookGovernorAbi = [{
  type: "function",
  name: "governor",
  stateMutability: "view",
  inputs: [],
  outputs: [{name: "", type: "address"}],
}] as const;

function LiveGovernance({
  chainId,
  governor,
  hook,
  positionManager,
}: {
  chainId: number;
  governor: `0x${string}`;
  hook: `0x${string}`;
  positionManager: `0x${string}`;
}) {
  const reads = useReadContracts({
    contracts: [
      {address: governor, abi: ownerAbi, functionName: "owner"},
      {address: governor, abi: governorAbi, functionName: "hook"},
      {address: hook, abi: hookGovernorAbi, functionName: "governor"},
      {address: positionManager, abi: ownerAbi, functionName: "owner"},
    ],
  });
  const owner = reads.data?.[0]?.result;
  const governorHook = reads.data?.[1]?.result;
  const hookGovernor = reads.data?.[2]?.result;
  const positionOwner = reads.data?.[3]?.result;
  const wired = same(governorHook, hook) && same(hookGovernor, governor) && same(positionOwner, owner);

  return (
    <div className="mt-5">
      <div className="border border-line px-5 py-3 font-mono text-[11px] uppercase tracking-[0.18em] text-muted">
        {reads.isLoading ? "Checking on-chain wiring…" : wired ? "On-chain wiring verified" : "Wiring mismatch"}
      </div>
      <Address label="Governor contract" address={governor} chainId={chainId} />
      <Address label="Multisig owner" address={owner} chainId={chainId} />
    </div>
  );
}

function same(a: string | undefined, b: string | undefined): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
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
