# WoolFi by Urufu Labs

[![CI](https://github.com/sp0oby/woolfi/actions/workflows/ci.yml/badge.svg)](https://github.com/sp0oby/woolfi/actions/workflows/ci.yml)
[![Spec](https://img.shields.io/badge/spec-v1.0--draft-1f6feb?labelColor=0d1117)](./PROJECT_SPEC.md)
[![Solidity](https://img.shields.io/badge/solidity-0.8.26-363636?labelColor=0d1117)](./foundry.toml)
[![License](https://img.shields.io/badge/license-BUSL--1.1%20%2F%20MIT-0aa?labelColor=0d1117)](#license)

**A multi-pool market for related assets on Robinhood Chain.**

WoolFi by Urufu Labs is a Uniswap v4 hook that turns a pool into a continuously-rebalancing pair-trade vehicle. The pool looks like an ordinary v4 pool from the outside. You swap, add liquidity, collect fees. The hook quietly enforces a peg between the pool's internal price and an oracle-derived fair price, weaving related assets into a venue for trading their *relationship* rather than just one against the other.

One hook serves an exact 16-pool catalog: seven stock/USDG oracle-guided spot pools, five stock/WETH crypto-beta pools (including PLTR/WETH), three stock/stock relative-value spreads, and always-open WETH/USDG. The coordinated rollout is all 16 ready or no launch.

## Using WoolFi, end to end

1. Connect a wallet on Robinhood Chain and choose a live pool.
2. To trade, approve the token you are paying and submit a swap. The hook compares the pool with
   oracle fair value, discounts corrective flow, and surcharges flow that increases the mismatch.
3. The router enforces the minimum output you accepted and sends the purchased token to your
   wallet. If that wallet holds an Urufu Gemu NFT, a funded rebate equal to 15% of the base-fee
   portion accrues in the input token; claim it from **NFT rebates**.
4. To earn LP fees, deposit both pool assets when the market is open and the pool is near fair
   value. Burn LP shares later to withdraw the current asset mix plus accrued fees.
5. To underwrite, stake URU in a pool vault. Underwriters may receive pool-token fee rewards but
   can lose a configured portion of staked URU during a structural break.
6. Traders close exposure with a reverse swap; LPs withdraw through **Provide liquidity**; URU
   stakers request withdrawal and wait through the seven-day cooldown.

No action is available while a pool is pending. Returns are not guaranteed: trading can move
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

WoolFi handles this with a per-pool underwriting vault capitalized with external URU. The hook caches the fair price that triggered the break, allows only corrective swaps against that target, blocks new deposits, and can trigger a capped vault drawdown. A configurable post-open stabilization interval keeps asymmetric fees off until the session settles. URU underwriting does not imply URU-based WoolFi governance.

LPs are insulated from the haircut; their tokens stay where they are, and withdrawals remain open the entire time.

The vault doesn't make breaks impossible. It makes them survivable.

## Urufu Gemu holder rebates

Wallets holding at least one verified Urufu Gemu NFT can earn 15% of WoolFi's base-fee portion
back in the token used for a swap. Rebates are recorded after successful router swaps, funded in
advance, and limited by a per-token weekly cap. The benefit does not stack across multiple NFTs,
does not rebate directional surcharges, and never draws from LP or underwriting principal.

## Market hours

Market hours are configured per pool. A stock-token pool cannot honestly promise convergence while its referenced market is closed and its underlying quote is not updating.

The hook handles this directly. When a configured underlying market is closed, the pool drops the asymmetric mechanic and reverts to flat, symmetric fees. The pool stays tradable without claiming to mean-revert until its market reopens. WETH/USDG is always open.

If you integrate tokenized real-world assets into an AMM, this is the detail that matters most. The pool's behavior changes when the underlying stops trading, and that change is enforced on-chain.

## Where the protocol is

The frontend is configured exclusively for Robinhood Chain and presents the exact catalog with explicit pending and live states. Today every pool is pending: no WoolFi protocol contract or pool is live on Robinhood Chain. Pending pools cannot be traded or funded. The protocol is unaudited.

| | |
|---|---|
| Spec | [`PROJECT_SPEC.md`](./PROJECT_SPEC.md) v1.0-draft |
| Source | Solidity 0.8.26, Foundry, BUSL-1.1 hook, MIT elsewhere |
| Tests | 181 passing &middot; 100k invariant calls clean &middot; [CI](https://github.com/sp0oby/woolfi/actions/workflows/ci.yml) |
| Network | Robinhood Chain |
| Catalog | Exact 16 pools; all currently pending |
| Audit | Not done; bug bounty pending audit |
| Dashboard | Next.js 14, wagmi/viem, reads configured live contracts |

Deployment state is read from the Robinhood Chain manifest and surfaced by the dashboard. Its
current zero core addresses and empty pool list are the canonical “not deployed” state.

## Architecture

```
WoolFiHook                beforeSwap / afterSwap, asymmetric fee, structural-break flag,
                         auto-realizes fees on every swap
WoolFiPositionManager     ERC-6909 LP shares, fee accumulator, vault and treasury routing
WoolFiUnderwritingVault   capped per-pool URU vault, drawdown bound to the hook
WoolFiGovernor            pool authorization, hook parameters, emergency controls
WoolFiSwapRouter          minimal IUnlockCallback wrapper for EOA swaps with slippage
WoolFiLiquidityZapper     guarded one-token LP path through allowlisted external routes
UrufuFeeRebateDistributor funded, capped base-fee rebates for Urufu Gemu NFT holders
oracle/                  Chainlink adapter, dual-oracle adapter, NyseHoursOracle (on-chain
                         NYSE calendar; production market-hours choice pending verification)
keeper/                  permissionless break checks from the Robinhood manifest
URU                      external underwriting asset for per-pool vaults
```

Every external entry point has NatSpec and a test file in `test/integration/` (round-trip behavior against a real v4 PoolManager) or `test/unit/` (math primitives).

## Robinhood Stock Token disclosure

Robinhood Stock Tokens provide economic exposure to referenced securities but do not provide ownership, voting rights, or other shareholder rights in the underlying securities. Issuer terms and geographic restrictions apply. WoolFi does not determine eligibility; users must confirm they may hold and trade each token.

## Governance

WoolFi v1 is administered by a multisig. It can authorize pools, update supported parameters, and use emergency controls within the contracts' permissions. URU underwriting does not imply URU voting rights.

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
coordinated launch is approved, live pools will read Robinhood Chain state and expose swap,
liquidity, and URU underwriting actions. Until then all 16 remain read-only.

## License

`src/WoolFiHook.sol` is Business Source License 1.1 with a two-year conversion to MIT, matching the Uniswap v4 model. Everything else is MIT.

## Acknowledgements

Uniswap Labs for v4 and the hooks framework.
