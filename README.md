# WoolFi by Urufu Labs

[![CI](https://github.com/sp0oby/woolfi/actions/workflows/ci.yml/badge.svg)](https://github.com/sp0oby/woolfi/actions/workflows/ci.yml)
[![Spec](https://img.shields.io/badge/spec-v1.0--draft-1f6feb?labelColor=0d1117)](./PROJECT_SPEC.md)
[![Solidity](https://img.shields.io/badge/solidity-0.8.26-363636?labelColor=0d1117)](./foundry.toml)
[![License](https://img.shields.io/badge/license-BUSL--1.1%20%2F%20MIT-0aa?labelColor=0d1117)](#license)

**A multi-pool market for related assets on Robinhood Chain.**

WoolFi by Urufu Labs is a Uniswap v4 hook that turns a pool into a continuously-rebalancing pair-trade vehicle. The pool looks like an ordinary v4 pool from the outside. You swap, add liquidity, collect fees. The hook quietly enforces a peg between the pool's internal price and an oracle-derived fair price, weaving related assets into a venue for trading their *relationship* rather than just one against the other.

One hook serves an exact 18-pool catalog: eight stock/USDG oracle-guided spot pools, five stock/WETH crypto-beta pools (including PLTR/WETH), four stock/stock relative-value spreads, and always-open WETH/USDG. All 18 pools go live together. WETH/USDG and NVDA/USDG are seeded at launch; the rest are open for the first liquidity providers, including one-click migration from Uniswap v3.

## Using WoolFi, end to end

1. Connect a wallet on Robinhood Chain and choose a pool. Seeded pools are listed first; a pool
   tagged "needs LP" is live but empty until its first liquidity provider arrives.
2. To trade, approve the token you are paying and submit a swap. The hook compares the pool with
   oracle fair value, discounts corrective flow, and surcharges flow that increases the mismatch.
   A single trade that would push the pool more than the hard threshold from Chainlink is
   rejected; try a smaller amount.
3. The router enforces the minimum output you accepted and sends the purchased token to your
   wallet. If that wallet holds an Urufu Gemu NFT, a funded rebate equal to 15% of the fee
   actually paid (capped at the base fee) accrues in the input token; claim it from **Rebate**.
4. To earn LP fees, deposit both pool assets, Zap in one token, or migrate a Uniswap v3
   position in one transaction (**Liquidity > Migrate v3**). Deposits need the market open and
   the pool near fair value. Burn LP shares later to withdraw the current asset mix plus fees.
5. To underwrite, stake URU in a pool vault. Underwriters may receive pool-token fee rewards but
   can lose a configured portion of staked URU during a structural break.
6. Traders close exposure with a reverse swap; LPs withdraw through **Liquidity**; URU
   stakers request withdrawal and wait through the seven-day cooldown.

No action is available before launch, while every pool is pre-launch. Returns are not guaranteed: trading can move
against the user, LP inventory can lose value, and underwriting is explicitly exposed to drawdown.

## The trade

If you wanted to express "the MSTR premium is too wide" on-chain today, you'd need a perp short on the equity side, spot on the crypto side, two collateral accounts, ongoing funding, and counterparty risk in two venues. Or you'd manage two concentrated-liquidity positions and rebalance them by hand every time the underlying moves.

WoolFi collapses all of that into a swap. You buy or sell the spread. The liquidity providers on the other side of your trade collect the fee. When the spread mean-reverts, LPs win; if it doesn't, the underwriting vault funds the rebalance back to fair.

## The mechanic

Each WoolFi pool is a full-range v4 pool with a dynamic LP fee. The hook runs at every callback.

In one paragraph: every swap routes through `beforeSwap`. The hook reads two oracle prices, computes the pool's drift from fair, and returns an asymmetric fee. Swaps that pull the pool back toward fair get a discount; swaps that push it further away pay a premium. The discount draws arbitrageurs in. The premium prices out adversarial flow. Mean-reversion stops being something a keeper has to do and becomes something the market does to itself.

A few things make this work without anyone actively managing the pool:

- Drift is computed on-chain, from primitive math against a Chainlink (or compatible) price feed. No off-chain solver, no transaction queue, no trusted operator.
- The fee scales with drift, not time. A pool sitting at fair earns the base fee. A pool 800 bps out of band might charge four times that to push it further out and a quarter to pull it back. The further the drift, the steeper the asymmetry.
- Liquidity providers stay passive. There's no concentrated-range maintenance. A full-range v4 mint is the whole UX.

## When correlations break

Correlations break. A balance sheet gets restated, an issuer halts redemptions, the link that looked fundamental turns out to be circumstantial.

WoolFi handles this with a per-pool underwriting vault capitalized with external URU. A break happens in two steps. **Detected:** the hook caches the fair price, allows only corrective swaps against that target, and blocks new deposits; nothing is drawn yet. **Confirmed:** after a waiting period of open-market time (default one hour), anyone can confirm; if the pool is still past the hard threshold, the vault is drawn down once, capped, to fund the rebalance, and if it has recovered the break clears with nothing taken. Once a confirmed pool is back in band, anyone can unlock it. The keeper bot makes these calls automatically. Separately, every swap is checked so no single trade can push an in-range pool past the hard threshold. A configurable post-open stabilization interval keeps asymmetric fees off until the session settles. URU underwriting does not imply URU-based WoolFi governance.

LPs are insulated from the haircut; their tokens stay where they are, and withdrawals remain open the entire time.

The vault doesn't make breaks impossible. It makes them survivable.

## Urufu Gemu holder rebates

Wallets holding at least one verified Urufu Gemu NFT earn back 15% of the fee they actually paid
on a swap, capped at the base fee, in the token used for the swap. Rebates are recorded after
successful router swaps on the settled input amount, funded in advance, and limited by a weekly
cap per wallet. The benefit does not stack across multiple NFTs, does not rebate directional
surcharges, and never draws from LP or underwriting principal.

## Market hours

Market hours are configured per pool. A stock-token pool cannot honestly promise convergence while its referenced market is closed and its underlying quote is not updating.

The hook handles this directly. When a configured underlying market is closed, the pool drops the asymmetric mechanic and reverts to flat, symmetric fees. The pool stays tradable without claiming to mean-revert until its market reopens. WETH/USDG is always open.

If you integrate tokenized real-world assets into an AMM, this is the detail that matters most. The pool's behavior changes when the underlying stops trading, and that change is enforced on-chain.

## Where the protocol is

The frontend is configured exclusively for Robinhood Chain and presents the exact catalog. Today every pool is pre-launch: no WoolFi protocol contract or pool is deployed on Robinhood Chain yet. At launch all 18 go live together; WETH/USDG and NVDA/USDG are seeded, and the other 16 show "needs LP" until their first deposit. The protocol is unaudited.

| | |
|---|---|
| Spec | [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) v1.0-draft |
| Source | Solidity 0.8.26, Foundry, BUSL-1.1 hook, MIT elsewhere |
| Tests | 486 forge tests + 30 live-fork tests against Robinhood Chain mainnet &middot; invariant suites clean &middot; [CI](https://github.com/sp0oby/woolfi/actions/workflows/ci.yml) |
| Network | Robinhood Chain |
| Catalog | 18 pools, all live together at launch; WETH/USDG and NVDA/USDG seeded |
| Audit | Not done; bug bounty pending audit |
| Dashboard | Next.js 14, wagmi/viem, reads configured live contracts |

Deployment state is read from the Robinhood Chain manifest and surfaced by the dashboard. Its
current zero core addresses and empty pool list are the canonical “not deployed” state.

## Architecture

```
WoolFiHook                beforeSwap / afterSwap, asymmetric fee, per-swap break guard,
                         two-step structural breaks (detect, confirm, recover),
                         auto-realizes fees on every swap
WoolFiPositionManager     ERC-6909 LP shares, fee accumulator, vault and treasury routing
WoolFiUnderwritingVault   capped per-pool URU vault, drawdown bound to the hook
WoolFiGovernor            pool authorization, hook parameters; owned by a 3-day timelock,
                         with an instant-pause-only guardian (the Safe)
WoolFiSwapRouter          minimal IUnlockCallback wrapper for EOA swaps with slippage
WoolFiLiquidityZapper     guarded one-token LP path through allowlisted external routes
UrufuFeeRebateDistributor funded, capped base-fee rebates for Urufu Gemu NFT holders
periphery/WoolFiV3Migrator   one-transaction Uniswap v3 position -> WoolFi LP migration
periphery/WoolFiArbExecutor  zero-capital v4 flash arb with a Uniswap v3 hedge
periphery/WoolFiPoolAligner  syncs an EMPTY pool to the Chainlink price at zero cost (permissionless)
oracle/                  Chainlink adapter, dual-oracle adapter, NyseHoursOracle (on-chain
                         NYSE calendar; production market-hours choice pending verification)
keeper/                  permissionless empty-pool sync and break detect / confirm / recover
arb-agent/               open-source arbitrage bot with an optional AI summary layer
URU                      external underwriting asset for per-pool vaults
```

Every external entry point has NatSpec and a test file in `test/integration/` (round-trip behavior against a real v4 PoolManager) or `test/unit/` (math primitives).

## Robinhood Stock Token disclosure

Robinhood Stock Tokens provide economic exposure to referenced securities but do not provide ownership, voting rights, or other shareholder rights in the underlying securities. Issuer terms and geographic restrictions apply. WoolFi does not determine eligibility; users must confirm they may hold and trade each token.

## Governance

WoolFi v1 is administered by a Safe multisig through an OpenZeppelin `TimelockController` with a 3-day minimum delay (longer than the 2-day unstake cooldown) and no admin. The timelock owns the governor, position manager, rebate distributor and zapper, so every settings change (pool authorization, oracles, fees, vault wiring, break resolution, unpausing) waits 24 hours in public and can be cancelled before it runs. The one instant power is the emergency pause: the Safe is the governor's guardian and can pause the hook immediately but cannot unpause or change anything else. Drawn-down URU goes to a rebalancer address that is neither the Safe nor the timelock. Break detection, confirmation, and recovery are permissionless. URU underwriting does not imply URU voting rights. Setup: [`docs/runbooks/multisig-setup.md`](./docs/runbooks/multisig-setup.md).

## Docs

- [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) - protocol specification
- [`docs/robinhood-deployment.md`](./docs/robinhood-deployment.md) - Robinhood deployment requirements
- [`SECURITY.md`](./SECURITY.md) - disclosure policy
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) - development setup and style

## Running locally

Prerequisites: [Foundry](https://book.getfoundry.sh/), Node 20+, and a Robinhood Chain RPC URL.

```bash
git clone https://github.com/sp0oby/woolfi.git
cd woolfi
forge install
forge build
forge test
```

The frontend lives in `frontend/`:

```bash
cd frontend
npm install
npm run dev          # http://localhost:3000
```

The splash and docs render at `/` and `/docs`; the multi-pool dashboard is at `/app`. Once the
launch is approved, all 18 pools read Robinhood Chain state and expose swap, liquidity, migration,
and URU underwriting actions. Until then all 18 remain read-only.

## License

`src/WoolFiHook.sol` is Business Source License 1.1 with a two-year conversion to MIT, matching the Uniswap v4 model. Everything else is MIT.

## Acknowledgements

Uniswap Labs for v4 and the hooks framework.

## Run the arbitrage agent

`arb-agent/` is an open-source bot that keeps WoolFi pools priced and earns the spread. When a
WoolFi pool drifts off its Chainlink fair price, it buys the cheap side on WoolFi (paying the
hook's discounted corrective fee) and sells it on the deep Uniswap v3 pool for the same pair, in
one transaction through `src/periphery/WoolFiArbExecutor.sol`. It needs no trading capital, only
gas: unprofitable trades revert. It runs in dry-run mode by default, and can optionally post
plain-English summaries of its activity using the Claude API. See
[`arb-agent/README.md`](./arb-agent/README.md).

```bash
cd arb-agent && npm install && cp .env.example .env && npm start
```
