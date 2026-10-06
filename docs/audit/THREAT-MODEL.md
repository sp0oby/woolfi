# Threat Model and Internal Findings

Internal review, 2026-10-06. Static analysis was not run (slither not installed). Findings are
manual and should be re-checked by the external auditor.

## Actors

Traders (via router or direct PoolManager), LPs (via position manager), URU underwriters,
arbitrageurs, the governance multisig, keeper operators, Chainlink, the Robinhood Stock Token
issuer (`oraclePaused()`), the Robinhood Chain sequencer operator, rebate funders.

## Assets at risk

LP principal and fees in the v4 pools; URU staked in 18 vaults; funded rebate balances; zap
inputs in flight; the governance role.

## Trust assumptions

- No L2 sequencer uptime feed exists on 4663 (spec 5.1). Sequencer downtime is not detected;
  users trust the chain operator directly.
- The Robinhood Stock Token issuer can pause oracle use via `oraclePaused()`; this fail-closes swaps.
- Chainlink feeds are live and honest. Heartbeat is 86400s, adapters allow 2x heartbeat.
- The multisig is honest (see Governance below for blast radius).
- Market-hours oracle owner is honest.

## Findings

Severity: Critical / High / Medium / Low / Info. Confidence: High / Medium / Low.

### H-1 Single-swap break guard is bypassed in flat-fee modes (High, confidence High)

`WoolFiHook.sol:412-416` (closed market / stabilization) and `:418-420` (oracle skew) do not
snapshot pre-drift, and `_afterSwap` skips both the guard and break flagging when
`asymmetricActive` is false (`:458-470`). Swaps in these modes can therefore push a pool far past
the hard threshold at the flat base fee. When normal mode resumes, the very next swap of any size
flags the break (pre-drift is already past the threshold so the guard does not fire, `:587`), and
`checkStructuralBreak` (`:372-380`) does the same permissionlessly. Result: a griefer can force a
URU drawdown on a thinly seeded pool, for roughly the cost of the mispricing arbitrageurs reclaim.
Two cheap windows: the final block of a stabilization window, and any oracle-skew window.
Fix: apply the guard on flat-fee paths too, measuring drift against the last oracle print without
the freshness check (or against `cachedFairPriceWad` semantics), or require a break to persist
across two observations separated in time before drawdown fires.

**Status: Fixed (both mitigations).** (1) The guard now runs on every non-break path. Closed
and stabilizing sessions measure drift against `getLastValidPrice()` on both legs (a new
`IPriceOracle` method: runtime guards and print validity apply, heartbeat freshness does not);
oracle-skew mode measures against the fresh but skewed prints. The pre-swap drift and the fair
price it was measured against are snapshotted in transient storage, and post-swap drift is
measured against the same fair. Asymmetric fees stay off in those modes. (2) Breaks are
two-phase: detection only flags containment and records `breakDetectedAt`; the drawdown waits
for permissionless `confirmStructuralBreak`, which re-reads the oracle with full freshness
after a governor-set window (default 1 hour, max 1 day) and either draws down once or clears.
Tests: `testRevert_guard_marketClosed`, `testRevert_guard_stabilization`,
`testRevert_guard_oracleSkew`, `testRevert_closedSwap_runtimeUnsafe`.

### M-1 Pre-positioning just under the threshold (Medium, confidence Medium)

The guard allows swaps up to `hardThresholdBps - 1` (`:586-589`). An actor can park drift at
1499 bps so any small adverse oracle update (feeds deviate at 0.5%) crosses the threshold and
`checkStructuralBreak` draws down URU. Arbitrageurs correct at a discount, so holding the position
is costly, but on thin pools it is cheap. Consider capping single-swap post-drift at a buffer below
the threshold (for example 80% of it).

**Status: Fixed by two-phase breaks.** An oracle step that tips a parked pool over the
threshold now only flags containment. During the confirmation window corrective swaps are
still admitted against the cached fair, so arbitrage can close the gap; if drift against a
fresh oracle read has recovered when `confirmStructuralBreak` runs, the break clears with no
drawdown (`StructuralBreakCleared`). A persisting break is drawn down at most once. The 80%
buffer was not added: with confirmation the residual cost of parking is the arbitrage the
parker gives away for the full window. Tests: `test_confirm_clearsWithoutDrawdownWhenRecovered`,
`test_confirm_drawsDownOncePerBreak`, `testRevert_confirm_tooEarly`,
`test_keep_clearsRecoveredBreak`.

### M-2 Rebate farming across wallets and discounted fees (Medium, confidence High)

`UrufuFeeRebateDistributor.sol:102-103` pays 15% of the configured base fee regardless of the fee
actually charged; corrective swaps can be charged close to 0 bps (`SpreadMath.sol:117`). The weekly
cap is per wallet (`:123-126`), not per NFT, and NFT balance is checked only at swap time (`:97`),
so one NFT moved between contract wallets gets a fresh cap each time. Loss is bounded by funded
balance. Fix: rebate on realized fee, cap per NFT token id, or require holding duration.

**Status: Fixed (realized fee); accepted (per-wallet cap).** The hook writes the LP fee it
applied to each swap into transient storage keyed by pool id and exposes
`lastSwapFeeBps(PoolId)`. The router calls `recordSwap` in the same transaction right after
settlement, and the distributor now rebates `amountIn * min(feeChargedBps, baseFeeBps) *
REBATE_BPS / 1e8`. A zero fee or a call outside a swap transaction yields zero rebate. Caps
cannot be keyed by token id: the Urufu Gemu NFT (`0x60cb7082...bd17`) answers false for
`supportsInterface(0x780e9d63)` (not ERC721Enumerable), checked on 4663. Per-wallet caps remain;
residual farming is bounded by the realized-fee rebate and by funding. Tests:
`test_rebate_correctiveSwapUsesChargedFee`, `test_rebate_adversarialSwapCappedAtBaseFee`.

### M-3 Compromised multisig can drain all URU (Medium as a trust risk, confidence High)

Via `WoolFiGovernor`, the owner can `updatePoolConfig` to a malicious oracle (`WoolFiHook.sol:239-254`),
force a break, `resolveStructuralBreak` (`:272-280`), and repeat with `setVault` at 9999 bps
(`:321-329`). Seized URU goes to the immutable vault `rebalancer` (`WoolFiUnderwritingVault.sol:210`),
which is the multisig itself. Stakers cannot exit faster than the 7 day cooldown. Recommend a
timelock on oracle, vault, and resolve actions, and an independent rebalancer address.

**Status: Mitigated operationally (no contract change).** See KNOWN-ISSUES.md: separate
rebalancer from the multisig and put a 24h+ `TimelockController` in front of the governor's
owner. Two-phase breaks also force a confirmation wait before every drawdown.

### L-1 One-step ownership remains on secondary contracts (Low)

`WoolFiLiquidityZapper.setOwner` (`:106`), `UrufuFeeRebateDistributor` (OZ `Ownable`),
`NyseHoursOracle` and `MultisigMarketHours` (OZ `Ownable`) are single-step.

**Status: Fixed.** The zapper has `transferOwnership` + `acceptOwnership` with `pendingOwner`;
the distributor and both market-hours oracles are `Ownable2Step`. Deploy scripts stage the
multisig, which must accept.

### L-2 Owner-controlled reverting sinks DoS swaps (Low)

Every swap calls `realizeFromHook` (`WoolFiHook.sol:479-482`), which transfers to `treasurySink`
and calls `vault.depositRewards` (`WoolFiPositionManager.sol:363-376`). A reverting sink or token
transfer reverts every swap on that pool. `setFeeConfig` does not check the vault matches the
hook's bound vault (`:131-142`).

**Status: Accepted** (owner-configured addresses; verify at
deploy via the launch-gate record).

### L-3 Market-hours owner controls fee mode (Low)

`NyseHoursOracle` holidays and DST table (`:148-182`) and `MultisigMarketHours.setOpen` can force
flat-fee mode (and with H-1, an unguarded window) or declare a closed market open. DST lookup is a
linear scan (`:205-214`), bounded by owner appends.

**Status: Accepted** (trust assumption);
the H-1 fix removes the unguarded window, and the owner is now two-step.

### L-4 No recovery path for rebate funds (Low)

`UrufuFeeRebateDistributor` has no sweep; unclaimed or overfunded tokens are locked.

**Status: Fixed.** `withdrawUnreserved(token, recipient, amount)` (owner only) can move at most
`balance - totalLiability`; accrued claims stay fully claimable
(`test_withdrawUnreserved_respectsLiabilities`).

### Info

- Reentrancy across the unlock boundary: not exposed. Router and PM `unlockCallback` check
  `msg.sender == poolManager` (`WoolFiSwapRouter.sol:90`, `WoolFiPositionManager.sol:282`); payer
  is always the original `msg.sender`; `swap`, `mint`, `burn`, `collectFees`, `realizeFromHook`,
  `zap` are `nonReentrant`.
- `realizeFromHook` trusts `msg.sender == key.hooks` (`WoolFiPositionManager.sol:271`) and the PM
  accepts any pool key. A foreign hook can only realize its own pool's PM position; no cross-pool
  impact found.
- Zapper: an allowlisted executor receives an exact, reset approval for `amountIn` of the input
  token (`WoolFiLiquidityZapper.sol:178-180`) and can at most take that amount; `minAmountOut` and
  `minShares` bound user loss. Governance must allowlist only swap routers: `plan.data` is
  user-supplied, so allowlisting a token contract would let calldata move zapper-held balances.
- Transient-storage guard: keyed per pool id and cleared at the end of every `_afterSwap`
  in `_afterSwap`. Re-checked after the H-1 fix: the snapshot (drift, armed flag, fair) and the
  per-swap fee slot are keyed per pool id; the snapshot is consumed on every swap. No leak found across pools. Nested same-pool swaps between
  `beforeSwap` and `afterSwap` are not possible in v4.
- SpreadMath: `poolPrice` intermediates fit at `MAX_SQRT_PRICE` (`SpreadMath.sol:60-62`); near
  `MIN_SQRT_PRICE` the price rounds to 0 and drift reads -10000 bps, no revert. 6/18 decimal
  pairs keep about 9 significant digits. Positive drift is clamped (`:81`).
- `BaseHook` coverage is 33%, by design (unused callbacks revert).
