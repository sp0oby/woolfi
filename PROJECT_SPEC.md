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

All symbols below refer to the canonical Robinhood Chain assets verified at launch. GLD/USDG and
GLD/SLV were temporarily removed while Chainlink had no GLD feed on Robinhood Chain; they were
restored once Chainlink published `GLD / USD` on 4663 (see `docs/oracles.md`).

### 3.1 Stock/USDG - oracle-guided spot pools

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

### 3.2 Stock/WETH - crypto-beta pools

These pools trade the relationship between a stock token and ETH rather than claiming a dollar
spot market.

9. MSTR/WETH
10. COIN/WETH
11. QQQ/WETH
12. NVDA/WETH
13. PLTR/WETH

### 3.3 Stock/stock - relative-value spreads

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
WoolFi inventory elsewhere. Existing external liquidity does not seed a WoolFi pool: seed-set pools
require their own approved initial liquidity and executable-route checks immediately before
launch, and the other pools start empty until community LPs or v3 migrations fill them
(section 9.1).

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
The rebate is computed from the pool's configured base fee, not the fee actually charged, so a
corrective swap that paid a discounted fee still receives the full base-fee rebate. This is
bounded by funding and the weekly cap.

## 5. Market hours and oracle safety

Stock-linked pools use equity-hours behavior. While the referenced market is closed, swaps remain
available at the flat base fee, asymmetric convergence is not promised, new liquidity is blocked,
and withdrawals remain open. WETH/USDG is always open.

Every production stock leg uses a guarded adapter that checks the Robinhood token's
`oraclePaused()` state and Chainlink round validity/freshness. On chains that publish an L2
sequencer uptime feed the adapter also checks sequencer status and the post-recovery grace
period; on Robinhood Chain today no such feed is available (see §5.1). Every non-stock leg also
requires a verified production oracle.

The following conditions are fail-closed and hard-revert swaps and liquidity additions on every
open-market fair-value path:

- stale, invalid, incomplete, or future-dated price data;
- a paused stock-token oracle;
- a down, invalid, or recently recovered sequencer when a sequencer uptime feed is configured;
- missing required oracle configuration.

Closed-market and post-open stabilization paths skip *price freshness* so weekend or holiday
prints do not freeze the pool. They still call `requireRuntimeGuards()` on both legs, so a
paused stock oracle, invalid last print, or (when configured) sequencer failure continues to
hard-revert.

### 5.1 Sequencer safety on Robinhood Chain

Robinhood Chain (4663) is an Arbitrum Orbit L2 whose sequencer is operated by the chain itself.
No L2 sequencer uptime feed is published for 4663, and [Chainlink has stated](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
it is not expanding that product to new networks. `RobinhoodStockOracleAdapter` therefore accepts
`sequencerUptimeFeed == address(0)` (paired with `gracePeriod == 0`) as an explicit opt-out that
skips the sequencer guard while preserving `oraclePaused()` and price-freshness enforcement.
A partial configuration reverts with `IncompleteSequencerConfig`.

The launch disclosure is that Robinhood Chain sequencer downtime is not distinguished from
ordinary block-production stall. Users of WoolFi on chain 4663 accept the operator's liveness
directly: the chain operator, the sequencer operator, and the stock-token issuer are the same
entity, so a WoolFi-operated uptime attestation reading the same chain would not add an
independent trust boundary. If Chainlink or another provider publishes a compatible sequencer
feed on 4663 in the future, governance may redeploy affected adapters with the guard enabled.

For two-leg fair-value calculations, an approved `maxOracleSkew` compares `getPriceData()`
timestamps. Excessive skew is a degraded mode: swaps continue at the flat base fee and
asymmetric/break detection is suppressed; new liquidity hard-reverts with `OracleTimestampSkew`.
Zero `maxOracleSkew` disables the check. Spread pools must configure a positive limit, sized to the
slower leg's heartbeat. Robinhood Chainlink feeds are deviation-triggered (0.5%) with a 24-hour
heartbeat, so two healthy legs routinely last-updated hours apart (observed: SPY vs QQQ about 2.9
hours). A gap between update times does not mean either price is wrong: each leg is within the
deviation threshold of its true value, or it is within its heartbeat. A limit measured in seconds
would therefore park a spread pool in degraded mode most of the time. Launch configuration uses
86400 seconds for every spread pool, and the readiness gate rejects any nonzero limit below the
slower leg's heartbeat.

## 6. Structural breaks

A structural break is drift at or beyond a pool's hard threshold. The intended production safety
model is:

1. Cache the fair price that triggered the break (`breakFair`).
2. Block new liquidity and disable ordinary asymmetric trading.
3. Permit only swaps proven to reduce drift against that cached `breakFair`.
4. Draw only within the approved per-pool URU cap and configured drawdown, and only after the
   break is confirmed (see below).
5. Keep withdrawals open.
6. Exit containment either permissionlessly once a confirmed break has recovered into the
   tolerance band, or through governed resolution.

Breaks are two-phase. Detection (by a swap or the permissionless `checkStructuralBreak`) only
contains the pool and records the detection time; no URU moves. A single swap may never cause a
break: the hook rejects any swap that would carry a pool from inside the hard threshold to beyond
it (`SwapWouldBreakPool`), in every mode. After a per-pool confirmation window (default 1 hour,
maximum 1 day), the permissionless `confirmStructuralBreak` re-reads a fresh oracle: if the pool is
still past the threshold the vault is drawn down once; if it recovered, the break clears with no
drawdown. For equity-hours pools the window counts from the later of detection and the current
session open, and confirmation is refused during the post-open stabilization window, so a break
flagged before a close cannot ripen over a weekend and be confirmed on the opening print before
corrective traders can act. After confirmation, `clearRecoveredBreak` lets anyone end containment
once a fresh oracle read shows drift back inside `toleranceBps` (market open, not stabilizing,
legs not skewed); the governor's `resolveStructuralBreak` remains available.

Using cached break fair prevents a moving or compromised oracle from redefining what “corrective”
means during containment. The post-open stabilization period is measured from
`IMarketHoursOracle.currentSessionStart()` and leaves always-open pools (WETH/USDG / address(0)
hours) unaffected.

The hook implements this model: it caches `cachedFairPriceWad` when a break is flagged, admits
only corrective swaps against that target, draws within the configured vault cap, and applies a
configurable `stabilizationSeconds` interval after the market opens. A confirmed break is cleared
by recovery or by governance. Runtime sequencer/pause guards remain in force during containment; a live fair-value
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

The public launch condition is **all 18 ready or no launch**. All 18 pools are deployed under one
all-or-nothing readiness gate, only the seed set is seeded, and the rest open for community LPs and
v3 migration. “Ready” means each pair has verified assets, both required oracles,
heartbeat/skew/market-hours settings, approved risk parameters, approved URU cap, a computed launch
price, completed dry runs, indexed metadata, and passing smoke checks; shared contracts and
services must also be ready. Approved initial liquidity is required only for the pools in
`seedSet` (section 9.1).

Deployment broadcasts are operationally **resumable and non-atomic**. The core, adapters, and
individual pools may require separate transactions or scripts. A failed or paused sequence must
resume from verified on-chain state; it must never fabricate addresses, mark incomplete pools
live, or imply that rollback is automatic.

Every broadcast requires explicit approval immediately before submission, including resumed
broadcasts. Deployment completion is not public launch authorization. If fewer than all 18 pools
are production-ready after deployment work, every pool remains pending and user actions remain
disabled.

### 9.1 Seed set and unseeded pools

Only the pools named in the batch config's `seedSet` receive initial seed liquidity at launch
(currently `weth-usdg` and `nvda-usdg`). The other 16 pools are still authorized, created, and
initialized at their computed launch `sqrtPriceX96` in the same coordinated deployment, with zero
liquidity. They go live with everything else, open to community LPs through the position manager,
the zapper, and the v3 migrator. The manifest marks seeded pools with `seeded: true` and the
frontend surfaces it as `CuratedPool.seeded`, so an unseeded live pool can invite its first LP.

Behavior of an empty pool, from `src/WoolFiHook.sol`:

- Drift is computed normally against the launch price in `slot0`. `checkStructuralBreak` does not
  revert on zero liquidity; it is a no-op unless drift reaches the hard threshold (it can still
  revert on a stale oracle, as on any pool).
- Deposits require drift inside the tolerance band (`OutOfBand` otherwise), an open and settled
  market, and no active break. If the oracle has moved past tolerance since the launch price, the
  first LP cannot deposit until the pool price is re-pegged. `WoolFiPoolAligner` does this
  (see "Empty-pool aligner" below).
- Phantom break risk: if the oracle moves past the hard threshold away from a stale empty-pool
  price, anyone (including the keeper) can flag a structural break, and `confirmStructuralBreak`
  then draws down that pool's vault even though no LP lost anything. A drawdown on an empty vault
  seizes nothing. Policy: do not fund treasury URU into an unseeded pool's vault until the pool
  has liquidity, and warn stakers on unseeded pools.
- Anyone can move an empty pool's price for free up to, but not across, the hard threshold (the
  single-swap break guard blocks crossing it). The first LP's deposit is still bounded by the
  tolerance band, so the worst case is depositing up to the tolerance away from fair. The UI should
  tell first LPs to check drift before depositing, and realign first (below).

Empty-pool aligner (`src/periphery/WoolFiPoolAligner.sol`). `align(key)` is permissionless, has no
owner, and holds no funds. It reverts unless the pool's PoolManager liquidity is zero. It reads fair
from the oracle adapters in the hook's pool config (`getLastValidPrice`; nothing is at stake in an
empty pool and the hook still applies its own oracle checks inside the swap), converts it to a
`sqrtPriceX96`, and swaps an exact input of 1 wei with that price as the limit. With zero liquidity
the price jumps to the limit and no tokens move: every balance delta is zero (enforced), so the
caller pays gas only (about 230k gas on a live fork). It is a no-op when the pool is already within
1 bps of fair.

- Hook modes: works live (fresh prints required, so a stale feed reverts), market closed and
  stabilizing (last valid print, flat fee), and oracle skew (flat fee). During a structural break the
  hook allows only swaps toward the cached target; if fresh fair lies the other way the aligner hops
  through the cached target first (drift zero there, so either direction passes), in one unlock.
  Reverts when the hook is paused or an oracle runtime guard fails (feed paused, invalid round).
- Phantom breaks: aligning a flagged empty pool before the confirmation window ends makes
  `confirmStructuralBreak` clear the break with no drawdown; after confirmation, align then
  `clearRecoveredBreak` unlocks it. Keeping empty pools aligned means the break check never trips.
- The keeper calls `align` for every pool before `checkStructuralBreak` (manifest `poolAligner`);
  seeded pools revert `PoolHasLiquidity` and are idle, aligned pools return false and are not
  broadcast. The frontend helper `needsAlign` tells the UI to send `align` before a first deposit.
- The zapper and v3 migrator do not align internally: a zap's swap plan is priced against the pool
  price at quote time, so moving the price inside the call would invalidate it.

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
- [ ] All 18 pool keys, launch prices, and risk parameters independently checked; seed amounts
      checked for the seed set.
- [ ] Per-pool and aggregate URU caps explicitly approved and funded only within those caps.
- [ ] Initial liquidity for the seed set (`weth-usdg`, `nvda-usdg`) approved and available.
- [ ] `WoolFiPoolAligner` deployed, recorded as `poolAligner`, wired into the keeper, and
      `test/fork/WoolFiPoolAligner.fork.t.sol` passing against chain ID 4663.
- [ ] No treasury URU funded into an unseeded pool's vault before that pool has liquidity.
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
