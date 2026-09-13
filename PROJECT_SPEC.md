# WoolFi Protocol Specification

**Version:** 1.0-draft · **Last updated:** August 2026 · **Status:** canonical pre-launch specification

This is the canonical specification for **WoolFi by Urufu Labs**. It defines the intended
production protocol on **Robinhood Chain (chain ID 4663)**. When another document disagrees,
this document wins. Remaining launch gaps are operational (audit, production inputs, and
broadcast approval), not missing hook safety mechanics.

## 1. Product and launch state

WoolFi is one Uniswap v4 hook serving a curated set of full-range pools. The hook compares each
pool price with oracle-derived fair value and uses a directional dynamic LP fee: flow toward fair
is discounted and flow away from fair is surcharged.

The production launch is a coordinated 18-pool market for Robinhood Stock Tokens, WETH, and USDG.
Per-pool underwriting uses the existing external **URU** token. WoolFi does not issue a production
token and does not provide URU governance rights.

**No WoolFi protocol contracts or pools are live on Robinhood Chain today.** The production
manifest contains no hook, position manager, governor, router, vault, oracle-adapter, or pool
deployment. Repository addresses for independently deployed Robinhood infrastructure and assets
are inputs to verify before launch, not evidence that WoolFi is deployed.

Legacy Base Sepolia deployments, mock assets, and STRAND contracts are non-production test and
reference artifacts only. They are not part of the Robinhood launch.

## 2. Production scope

### 2.1 Required for launch

- Robinhood Chain only (chain ID 4663).
- One permission-mined `WoolFiHook` shared by exactly the 18 authorized pools in §3.
- One position manager, swap router, governor, and production multisig control plane.
- One URU-denominated underwriting vault per pool, each with an approved cap.
- Full-range ERC-6909 LP shares and fee routing through the position manager.
- Verified token contracts, price feeds, heartbeat settings, market-hours configuration, and
  sequencer safety controls for every pool.
- Frontend, indexer, keeper, monitoring, audit, and incident-response readiness.

WoolFi integrates Robinhood Stock Tokens; it does not issue, redeem, custody, or determine
eligibility for them. Issuer terms and geographic restrictions remain applicable.

### 2.2 Explicitly outside the production design

- Base or Base Sepolia as a live WoolFi network.
- Backed/xStocks, Ondo, or Dinari assets or issuer dependencies.
- MSTRX/cbBTC or any cbBTC production pool.
- STRAND issuance, staking, governance, sale, or production underwriting.
- Concentrated WoolFi liquidity, native ETH legs, fee-on-transfer tokens, or rebasing vault assets.
- A partial public launch of the curated catalog.

## 3. Canonical 18-pool catalog

All symbols below refer to the canonical Robinhood Chain assets verified at launch.

### 3.1 Stock/USDG — oracle-guided spot pools

These pools provide stock-token spot exposure quoted in USDG. Fair value is the stock/USD price
relative to USDG/USD.

1. MSTR/USDG
2. COIN/USDG
3. CRCL/USDG
4. NVDA/USDG
5. SPY/USDG
6. GLD/USDG
7. AAPL/USDG
8. TSLA/USDG

### 3.2 Stock/WETH — crypto-beta pools

These pools trade the relationship between a stock token and ETH rather than claiming a dollar
spot market.

9. MSTR/WETH
10. COIN/WETH
11. QQQ/WETH
12. NVDA/WETH
13. PLTR/WETH

### 3.3 Stock/stock — relative-value spreads

These pools express relative value between related equities or ETFs.

14. AAPL/MSFT
15. SPY/NVDA
16. SPY/QQQ
17. GLD/SLV

### 3.4 Always-open crypto spot

18. WETH/USDG

WETH/USDG has no equity-market-hours gate. It remains subject to feed freshness and sequencer
safety requirements.

The catalog favors assets with observable Robinhood Chain liquidity so arbitrageurs can hedge
WoolFi inventory elsewhere. Existing external liquidity does not seed a WoolFi pool: every pool
still requires its own approved initial liquidity and executable-route checks immediately before
launch.

## 4. Price and fee mechanics

Tokens map to `token0` and `token1` by canonical address ordering. Oracle prices are normalized to
1e18 USD values.

```text
fair_price = price_token0 / price_token1
pool_price = (sqrtPriceX96 / 2^96)^2 * 10^(decimals0-decimals1)
drift      = (pool_price - fair_price) / fair_price
```

Each pool is in band when `abs(drift) <= toleranceBps`. In band, the base LP fee applies. Out of
band, a swap that reduces absolute drift is corrective and receives a discount; a swap that
increases absolute drift is adversarial and receives a surcharge. Fees are capped by contract
configuration.

Pools are full-range only. New liquidity is accepted only when configured, unpaused, market-open
when applicable, and in band. Withdrawals remain available at the current pool ratio.

### 4.1 Urufu Gemu holder rebates

The production swap router may connect to an optional `UrufuFeeRebateDistributor`. A wallet that
holds at least one verified Urufu Gemu NFT when its swap settles earns 15% of that pool's base-fee
portion back in the swap's input token. The directional surcharge is never rebated, NFT quantity
does not stack the benefit, and credits already earned remain with the trading wallet after an NFT
transfer.

Rebates accrue only through the verified WoolFi router, only for funded tokens with a
multisig-approved per-wallet weekly cap, and only against the hook's configured base fee. The
distributor reserves funded assets as credits accrue, preventing unfunded liabilities. Its
post-swap call is fail-open: rebate failure must never revert an otherwise valid swap. Rebate
funding is a capped loyalty budget and is separate from LP principal and URU underwriting assets.

## 5. Market hours and oracle safety

Stock-linked pools use equity-hours behavior. While the referenced market is closed, swaps remain
available at the flat base fee, asymmetric convergence is not promised, new liquidity is blocked,
and withdrawals remain open. WETH/USDG is always open.

Every production stock leg uses a guarded adapter that checks the Robinhood token's
`oraclePaused()` state, Chainlink round validity and freshness, and Robinhood sequencer status plus
post-recovery grace period. Every non-stock leg also requires a verified production oracle.

The following conditions are fail-closed and hard-revert swaps and liquidity additions on every
open-market fair-value path:

- stale, invalid, incomplete, or future-dated price data;
- a paused stock-token oracle;
- a down, invalid, or recently recovered sequencer;
- missing required oracle configuration.

Closed-market and post-open stabilization paths skip *price freshness* so weekend or holiday
prints do not freeze the pool. They still call `requireRuntimeGuards()` on both legs, so a
paused stock oracle, down sequencer, or invalid last print continues to hard-revert.

For two-leg fair-value calculations, an approved `maxOracleSkew` compares `getPriceData()`
timestamps. Excessive skew is a degraded mode: swaps continue at the flat base fee and
asymmetric/break detection is suppressed; new liquidity hard-reverts with `OracleTimestampSkew`.
Zero `maxOracleSkew` disables the check. Spread pools must configure a positive limit.

## 6. Structural breaks

A structural break is drift at or beyond a pool's hard threshold. The intended production safety
model is:

1. Cache the fair price that triggered the break (`breakFair`).
2. Block new liquidity and disable ordinary asymmetric trading.
3. Permit only swaps proven to reduce drift against that cached `breakFair`.
4. Draw only within the approved per-pool URU cap and configured drawdown.
5. Keep withdrawals open.
6. Require governed resolution and a post-open stabilization period before normal operation.

Using cached break fair prevents a moving or compromised oracle from redefining what “corrective”
means during containment. The post-open stabilization period is measured from
`IMarketHoursOracle.currentSessionStart()` and leaves always-open pools (WETH/USDG / address(0)
hours) unaffected.

The hook implements this model: it caches `cachedFairPriceWad` when a break is flagged, admits
only corrective swaps against that target, draws within the configured vault cap, and applies a
configurable `stabilizationSeconds` interval after the market opens. Governance still clears the
break flag. Runtime sequencer/pause guards remain in force during containment; a live fair-value
print is not required to classify corrective flow.

## 7. Contracts and off-chain services

- `WoolFiHook`: shared v4 hook, pool authorization, fee logic, market-hours gating, break state.
- `WoolFiPositionManager`: shared full-range position, ERC-6909 shares, fee realization/routing.
- `WoolFiUnderwritingVault`: per-pool vault using an externally supplied standard ERC-20; URU in
  Robinhood production.
- `WoolFiGovernor`: multisig-owned pool configuration and emergency control surface.
- `WoolFiSwapRouter`: exact-input EOA swap path with minimum-output protection.
- `WoolFiLiquidityZapper`: optional one-token LP path. It wraps native ETH when requested, permits
  only governance-allowlisted external executors with exact approvals, verifies both route outputs,
  enforces minimum LP shares and deadlines, and refunds all unused input. Balancing routes must not
  trade against the target WoolFi pool.
- `UrufuFeeRebateDistributor`: optional funded, capped input-token rebates for Urufu Gemu holders.
- `RobinhoodStockOracleAdapter`: stock pause, feed validity/staleness, and sequencer guards.
- `RebalanceKeeper`: permissionless no-swap break checks; required keeper operations must be
  monitored even though ordinary fee realization occurs in-hook.
- Indexer: all 18 pools, swaps, LP shares, fee routing, vault state, breaks, and deployment blocks.

Production requires the position-manager wiring, router, zapper/executor, indexer, keeper, and
frontend to point to the same verified deployment manifest.

## 8. Governance and underwriting

Production administration is multisig-controlled. The multisig authorizes pools, configures
oracles and risk parameters, wires vaults and fee routing, manages emergency pause, and approves
break resolution. URU is external underwriting capital, not a WoolFi-issued or WoolFi-governance
token.

Every vault has an explicit URU cap. Per-pool caps and the aggregate treasury allocation require
multisig approval before funding. Vault rewards may receive a configured share of pool fees.
No documentation or interface may imply that underwriting eliminates LP loss.

The launch default for realized pool fees is 20% to active URU vault stakers, 10% to the
multisig-controlled treasury policy, and 70% to LPs. If a configured vault has no stakers, its
share folds back to LPs. The treasury allocation may fund approved rebates and protocol operations;
it is not an automatic STRAND or URU buyback. Any per-pool override requires launch-record approval.

## 9. Coordinated rollout

The public launch condition is **all 18 ready or no launch**. “Ready” means each pair has verified
assets, both required oracles, heartbeat/skew/market-hours settings, approved risk parameters,
approved URU cap, approved initial liquidity, completed dry runs, indexed metadata, and passing
smoke checks; shared contracts and services must also be ready.

Deployment broadcasts are operationally **resumable and non-atomic**. The core, adapters, and
individual pools may require separate transactions or scripts. A failed or paused sequence must
resume from verified on-chain state; it must never fabricate addresses, mark incomplete pools
live, or imply that rollback is automatic.

Every broadcast requires explicit approval immediately before submission, including resumed
broadcasts. Deployment completion is not public launch authorization. If fewer than all 18 pools
are production-ready after deployment work, every pool remains pending and user actions remain
disabled.

## 10. Launch gates

- [ ] External audit complete; no unresolved critical/high findings.
- [ ] Production multisig created, signers/recovery verified, and ownership handoff tested.
- [ ] Hook, position manager, governor, router, vault implementation, and deployment scripts frozen.
- [ ] Position manager wired to the hook and fee routing configured.
- [ ] Router configured and end-to-end slippage tests passed.
- [ ] Urufu Gemu NFT address, rebate distributor/router binding, token budgets, and weekly caps verified.
- [ ] Indexer configured for all pool/vault mappings and production start blocks.
- [ ] Keeper deployed/configured, funded if needed, monitored, and exercised.
- [ ] Corrective-only cached-fair breaks, post-open stabilization, and timestamp-skew checks
      audited (implemented and covered in-repo).
- [ ] All stock pause guards, feeds, heartbeats, sequencer guards, and market-hours sources verified.
- [ ] All 18 pool keys, initial prices, risk parameters, and liquidity amounts independently checked.
- [ ] Per-pool and aggregate URU caps explicitly approved and funded only within those caps.
- [ ] Initial liquidity for all 18 pools approved and available.
- [ ] Frontend and manifest show no pool live until the coordinated launch decision.
- [ ] Monitoring, incident runbooks, security contact, and bug bounty ready.
- [ ] Dry runs and read-only fork checks pass against chain ID 4663.
- [ ] Explicit multisig approval recorded for each broadcast or resumed broadcast.
- [ ] Post-broadcast source verification, wiring checks, and read-only smoke checks pass for all 18.
- [ ] Final coordinated go/no-go approval recorded; otherwise no public launch.

See [`docs/robinhood-deployment.md`](./docs/robinhood-deployment.md) for the operational sequence
and [`docs/oracles.md`](./docs/oracles.md) for oracle behavior.

## 11. Security and disclosure

WoolFi is pre-launch and unaudited until the launch gates say otherwise. Robinhood Stock Tokens
provide economic exposure, not ownership, voting, or other shareholder rights in referenced
securities. WoolFi does not determine user eligibility.

Oracle manipulation, timestamp mismatch, sequencer outages, market gaps, structural breaks,
underfunded vaults, privileged misconfiguration, deployment interruption, and indexer/frontend
divergence are first-class threats. Production claims must describe deployed and verified behavior,
not planned behavior.
