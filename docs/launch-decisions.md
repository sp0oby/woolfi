# Launch Decisions (Recommended)

Recommendations for the open owner decisions in `TODO.md`. Each one says what to choose, why, and
what still needs a person. **These are proposals, not approvals.** Nothing here prefills the
launch-gate record, the approved batch config, or any address; record the final choice and its
approval reference in `docs/runbooks/launch-gate-record.md` when it is made.

| # | Decision | Recommendation |
|---|---|---|
| 1 | Production multisig | Safe on chain 4663, **3-of-5**, hardware-wallet signers, at least 2 outside the core team |
| 2 | Vault rebalancer | A **second Safe**, 2-of-3, with signers not on the production Safe |
| 3 | URU caps and funding | Size caps from expected pool value; fund **only the seed set's vaults** at launch |
| 4 | Seed liquidity | **Both** WETH/USDG and NVDA/USDG with small team seeds (e.g. ~$1k and less), 100 bps slippage; the other 16 filled by LPs migrating ~$40M of existing v3 liquidity |
| 5 | Market-hours source | **`NyseHoursOracle`** for all 17 equity pools, owned by the Safe |
| 6 | `maxOracleSkew` outside spread pools | **Keep 0** (disabled) for stock/USDG and stock/WETH |
| 7 | RPC provider | A paid **Dwellir or QuickNode** Robinhood Chain endpoint; public RPC as fallback only |

## 1. Production multisig

**Recommend:** SafeL2 1.4.1 on chain 4663 (see `runbooks/multisig-setup.md`), **3-of-5**.

- Every signer is a hardware wallet held by a different person, on a device used for nothing else.
- At least two signers are outside the core team (for example an advisor and a trusted
  operator), so the team alone cannot meet the threshold and one compromised team laptop cannot
  either.
- 3-of-5 survives losing any two keys. 2-of-3, the runbook's floor, survives losing only one, and
  the Safe is also the instant-pause guardian, so availability matters.
- **Recovery:** the remaining signers rotate a lost or compromised key with `swapOwner`, which
  needs the threshold. Each signer stores a seed backup separately from their device. Keep a
  signer contact sheet and an emergency-pause procedure in the incident runbook.
- If there are only two or three people to sign at launch, use 2-of-3 and move to 3-of-5 before
  the URU caps grow.

**Needs a person:** choose the signers, create the Safe, record its address and owner set.

## 2. Vault rebalancer

**Recommend:** a **separate Safe, 2-of-3**, where at least two signers are not on the production
Safe.

- Each vault's `rebalancer` is **immutable** once the pool is created and receives the URU taken in
  a confirmed break. It must be an address that can never be lost: a Safe can rotate its signers;
  an EOA or a one-off contract cannot be fixed later.
- It must not be the production Safe or the timelock (KNOWN-ISSUES M-3; the batch validator
  enforces this).
- A rebalance-executor **contract** would need its own audit, and because the address is
  immutable per vault, a bug in it could not be fixed. Revisit only after launch, when it can be
  introduced for new vaults.

**Needs a person:** choose its signers and create it before any pool is created.

## 3. URU caps and funding

The vault exists to fund a rebalance after a confirmed break. A confirmed break draws at most
`drawdownBps` of the vault (default **20%**), so the cap decides how much a break can pay.

**Starting rule (a judgment call, not a derivation):** for a pool expected to hold `V` dollars of
liquidity, cap the vault at roughly **0.4 × V in URU value**. One confirmed break then draws about
8% of `V`, the same order as the loss a pool takes when it is pushed past the 15% hard threshold,
while keeping URU at risk proportionate to the pool. Convert the dollar amount to URU at the
launch price, and revisit after the first months of real break and drift data.

With `S` = the dollar value you seed into a pool (section 4):

| Pool group | Cap (URU value) | Treasury funding at launch |
|---|---|---|
| WETH/USDG, NVDA/USDG (seeded) | ~0.4 × the value you expect the pool to reach, so outside stakers have room | **~0.4 × S** (about $400 of URU for a $1,000 seed) |
| Each of the 16 unseeded pools | ~0.4 × the value you expect it to reach | **None** until the pool has liquidity |
| **Aggregate cap** (`totalTreasuryAllocationCap`) | sum of all 18 caps | |

A cap is a ceiling, not a commitment: setting it costs nothing, and only the URU actually staked
is at risk.

- **Do not fund unseeded vaults at launch** (spec §9.1). An empty pool can drift and be flagged,
  and a confirmed break would draw URU even though no LP lost anything. The keeper keeps empty
  pools aligned to Chainlink, but funding only after first liquidity removes the risk entirely.
- Caps must be positive for every pool (the validator requires it), so set the unseeded caps now
  and leave them unfunded.
- Raise caps through the timelock as pools grow; the 3-day delay gives stakers time to react.

**Needs a person:** the URU launch price, the treasury's approval of the aggregate amount, and
whether to raise the seed-pool caps above the funded amount so public stakers can join.

## 4. Seed liquidity and the liquidity plan

The team is **not** funding deep liquidity. The seed's job is to make one pool live and show the
mechanism working; depth comes from outside LPs, mostly by migrating existing Uniswap v3
positions (one transaction per position with `WoolFiV3Migrator`, uncollected fees included).

A Uniswap v4 hook is fixed when a pool is created, so WoolFi cannot attach to existing pools. It
can attract their liquidity.

**Decided:** keep the seed set as **WETH/USDG and NVDA/USDG**, both seeded with small amounts
from the team's budget (for example about $1,000 in one and less in the other), split evenly by
value at the launch price, `slippageBps: 100`. The other 16 open for the first LPs.

- **What a small seed supports:** with about $500 a side, a ~$2.50 swap moves the price about 1%,
  and swaps above ~$36 hit the hook's 15% per-swap guard and revert. With about $50 a side, the
  limit is ~$3.60. It is a working demonstration, not a market; arbitrage will be the main early
  flow.
- NVDA/USDG has a deep v3 pool (~$2.7M at 0.05%) that the zero-capital arbitrage agent can trade
  against to keep the WoolFi pool priced. WETH/USDG's v3 pool charges 0.01% on ~$20M, so few
  swaps will route to WoolFi's 0.3% base fee there; it is still useful as the one pool open on
  weekends.
- **Other users seed the rest from the terminal:** Liquidity → Deposit → **Migrate** lists the
  connected wallet's v3 positions for that pair and moves one in a single transaction (Zap and a
  plain two-token deposit work too). An empty pool first shows "Sync to Chainlink price", which
  the keeper normally does already. Deposits into equity pools need the market open and past the
  opening window.
- **The migrator must be deployed for this to work.** It is a separate step
  (`script/DeployV3Migrator.s.sol`); until `v3Migrator` is in the manifest the Migrate tab stays
  disabled. The `readiness` gate now requires it.

### Existing Uniswap v3 liquidity per catalog pair

Read on chain 4663 on 2026-10-13 (Uniswap v3 factory `0x1f7d…2EfA`). Values are approximate:
everything the pool contract holds, uncollected fees included, priced from the deepest USDG
pool. SLV has no USDG pool, so GLD/SLV is only partly valued.

| WoolFi pair | v3 liquidity (all fee tiers) | Deepest tier |
|---|---|---|
| WETH/USDG | ~$27M | 0.01% (~$20M) |
| GLD/USDG | ~$3.8M | 0.3% |
| NVDA/USDG | ~$2.7M | 0.05% |
| CRCL/USDG | ~$2.4M | 0.3% |
| NVDA/WETH | ~$1.2M | 0.05% |
| COIN/WETH | ~$800k | 0.3% |
| MSTR/USDG | ~$560k | 1% |
| MSTR/WETH | ~$540k | 1% |
| TSLA/USDG | ~$430k | 0.3% |
| AAPL/USDG | ~$390k | 0.05% |
| QQQ/WETH | ~$280k | 0.3% |
| SPY/USDG | ~$270k | 0.05% |
| SPY/QQQ | ~$51k | 0.05% |
| PLTR/WETH | ~$28k | 0.3% |
| GLD/SLV | GLD side ~$15k; SLV not priced | 0.05% |
| SPY/NVDA | ~$5k | 0.05% |
| COIN/USDG | ~$2k | 0.05% |
| AAPL/MSFT | no v3 pool | none |

About **$40M** across the catalog. Outreach order: GLD/USDG, NVDA/USDG, CRCL/USDG, NVDA/WETH and
COIN/WETH hold the most stock-pair liquidity. Most v3 LPs run concentrated ranges, while WoolFi
positions are full range, so the pitch is fee quality and protection (asymmetric fees, market-hours
handling, break underwriting, the Urufu Gemu rebate), not capital efficiency.

### URU

- **Stake** about **0.4 × each seed's value** (~$400 of URU for a $1,000 seed) in the seeded pools'
  vaults (section 3). Staked URU earns a share of that pool's fees and can lose up to the
  configured 20% in a confirmed break.
- **Keep the rest as an incentive for early LPs**, for example a monthly URU distribution
  proportional to WoolFi LP shares held. WoolFi has no on-chain LP-reward contract, so this would
  be a manual or Merkle-claim distribution from the treasury. Announce the rule before launch so
  v3 LPs can price it in.
- Do not stake treasury URU in an unseeded pool's vault until it has liquidity (section 3).

### Seeding mechanics

- **Slippage is now enforced against the approved launch price.** `SeedInitialLiquidity.s.sol`
  computes the shares the approved amounts would mint at the config's `sqrtPriceX96` and requires
  at least that minus `slippageBps` (capped at 10%). Before this change, `slippageBps` was
  validated but never used, and the only protection was `minShares`, defaulting to 1.
- 100 bps (1%) suits two volatile assets. Recompute the launch prices (`compute_launch_prices`)
  right before seeding; if the price moves more than 1% first, the seed reverts instead of
  depositing at a stale ratio. Re-run with fresh prices.
- **Seed NVDA/USDG during NYSE hours, at least 15 minutes after the open.** The hook refuses
  liquidity in equity pools while the market is closed (`MarketClosed`) and during the opening
  stabilization window (`StabilizationActive`, 900 seconds by default). WETH/USDG is always open.

**Needs a person:** the capital, its source wallet, and the approval record.

## 5. Market-hours source

**Recommend:** **`NyseHoursOracle`** for all 17 equity pools, owned by the production Safe.

- `MultisigMarketHours` needs a Safe transaction to open and another to close every trading day,
  about 500 signed transactions a year. A missed flip leaves pools trading with the wrong fee mode.
  It is not operable with a 3-of-5 Safe.
- `NyseHoursOracle` computes regular hours on-chain, including daylight saving and NYSE
  holidays, with no keeper and no off-chain feed.
- **Its limits, and how to cover them:**
  - The holiday list and daylight-saving table run through **2027**. Add 2028 with `setHolidays`
    and a new daylight-saving window before November 2027 (the Safe owns the oracle directly, so
    this does not wait on the timelock). Put a calendar reminder in the ops runbook.
  - **Early-close days** (the day after Thanksgiving, Christmas Eve) count as full days, so pools
    would stay in asymmetric mode until 4 PM ET after the stock feeds stop. Recommend marking each
    early-close day as a holiday with `setHolidays` ahead of time: the pools then run flat fees
    all day, which is the conservative side.
  - **Unscheduled closures** (market-wide halts, national days of mourning): the Safe marks the
    day with `setHoliday`, which takes effect immediately.
  - Do **not** use the guardian pause for calendar issues. Pausing is instant, but unpausing goes
    through the 3-day timelock, so a short pause would stop the hook for days.

**Needs a person:** deploy it (`DeployNyseHoursAndSwap.s.sol`), set `core.marketHours`, and add the
calendar task to the ops runbook.

## 6. `maxOracleSkew` for stock/USDG and stock/WETH

**Recommend:** **keep 0** (disabled) for these 13 pools. The 4 stock/stock spread pools keep 86400.

- The validator requires any non-zero skew to be at least the slower leg's heartbeat, which is
  86400 seconds (24h) for every Robinhood Chainlink feed. A smaller value would park pools in
  degraded mode during normal quiet periods.
- In these pools one leg is USDG or ETH, which update far more often than the stock leg. A skew
  limit of 24h or more would essentially never trigger, so it adds configuration without adding
  protection.
- Each leg is already bounded on its own: the adapters reject stale, paused and incomplete rounds.
- Spread pools differ: both legs are stocks on the same schedule, so a gap between them is
  meaningful, and 86400 is the tightest value the heartbeat allows.

**Needs a person:** nothing beyond confirming this; the current example config already reflects
it.

## 7. RPC provider

**Recommend:** a paid Robinhood Chain endpoint from **Dwellir** (publishes an archive endpoint for
chain 4663) or **QuickNode**. Robinhood's own docs point high-volume use to dedicated providers;
the public RPC is rate-limited with no SLA.

- Use **separate keys** for CI (the `ROBINHOOD_RPC_URL` secret), the keeper and indexer, and the
  frontend (`NEXT_PUBLIC_ROBINHOOD_RPC_URL`, which is visible to users, so restrict it by domain
  in the provider dashboard).
- Keep `https://rpc.mainnet.chain.robinhood.com` only as a fallback.
- Before relying on any endpoint, confirm `eth_chainId` returns `0x1237`.
- Provider support for this chain is changing quickly; check the provider's own chain list when
  signing up.

**Needs a person:** sign up and pay, then set the secrets and env vars. The Alchemy account is
suspended.
