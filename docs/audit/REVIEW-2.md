# Review 2: post-fix adversarial pass (commit 72535a5)

Scope: the all-modes single-swap guard, two-phase breaks, getLastValidPrice, the realized-fee
rebate, RebalanceKeeper confirm path, withdrawUnreserved, two-step ownership. Read-only.

## Status

| ID | Status | Change |
| --- | --- | --- |
| R2-1 | Fixed | Spread pools `maxOracleSkew` 120 -> 86400 in the batch config; `robinhood_batch.py` rejects a nonzero skew below the slower leg's heartbeat (`test_rejects_spread_skew_tighter_than_heartbeat`); fork test `test_fork_spreadPoolSkewConfigUnderLiveFeeds` reads the config and passes against live SPY/QQQ (gap 10,553s); PROJECT_SPEC section 5 and docs/oracles.md explain the sizing. |
| R2-2 | Fixed | `confirmStructuralBreak` reverts `StabilizationActive` during stabilization; equity-hours windows count from `max(detectedAt, currentSessionStart())`; `breakStatus.confirmReadyAt` is `type(uint256).max` while closed; always-open pools keep wall-clock. Keeper skips via try/catch. |
| R2-3 | Fixed | Indexer ABI, `break_episode` / `pool_break_pointer` / `break_confirm_setting` tables and handlers for Confirmed, Cleared, Recovered, DrawdownFailed, BreakConfirmSecondsSet; episodes close on Cleared, Recovered or Resolved. |
| R2-4 | Fixed | Permissionless `clearRecoveredBreak(key)`: confirmed break only, market open, not stabilizing, legs not skewed, fresh drift within `toleranceBps`; emits `StructuralBreakRecovered`. `RebalanceKeeper.keep` attempts it and emits `RecoveryAttempted`. |
| R2-5 | Accepted | Operational: run an arbitrage keeper per pool (see KNOWN-ISSUES). |
| R2-6 | Fixed | Router decodes the settled input from the unlock callback and passes it to `recordSwap` and the `Swap` event. |

Regression tests: `test/integration/Review2Fixes.t.sol` (13 tests).

## Findings

**R2-1 High (confidence high): spread pools are effectively always "skewed".**
`WoolFiHook.sol:752-759` treats legs whose `updatedAt` differ by more than `maxOracleSkew` as
skewed. The example config sets 120s on all four spread pools
(`script/config/robinhood-batch.example.json:80-83`), but Robinhood Chainlink feeds update on a
0.5% deviation or 24h heartbeat. Live reads on 2026-10-07 showed leg gaps of 1.4h-3.4h on every
spread pair. Consequences:
- deposits always revert `OracleTimestampSkew` (`:618`), so the pools can never be seeded;
- `checkStructuralBreak` and `afterSwap` never flag (`:444`, `:571`), so breaks are undetectable;
- `confirmStructuralBreak` reverts (`:469`), so a flagged break can only be resolved by the
  governor.
Fix: size `maxOracleSkew` from observed feed cadence (hours, not seconds), or base skew on
"both legs updated since `currentSessionStart()`". Add a fork test asserting each spread pool
is not skewed at a market-hours block.

**R2-2 Medium (confidence medium): the confirmation can be raced at the market open.**
The confirmation window is wall-clock (`:465`), and confirm is allowed during stabilization
(only `MarketClosed` is checked, `:467`). If a break is flagged before Friday's close, the window
elapses over the weekend. At Monday's open an MEV bot can backrun the first Chainlink update with
`confirmStructuralBreak` before any arbitrage has traded against the fresh price, drawing down
URU on a weekend gap.
Fix: also revert inside the stabilization window, and/or count the window only from
`max(detectedAt, currentSessionStart())`.

**R2-3 Medium (confidence high): the indexer misses new break transitions.**
`StructuralBreakConfirmed`, `StructuralBreakCleared`, `DrawdownFailed` and
`BreakConfirmSecondsSet` are emitted (`:474,478,486,315`) but are not in `indexer/abis/index.ts`
or handled in `indexer/src/index.ts`. A break that clears on its own (no governor `Resolved`)
stays open in indexed history forever.
Fix: add the ABI entries and handlers; close the break row on `Cleared`.

**R2-4 Low: a confirmed break never exits on its own.**
After confirmation the pool stays corrective-only with deposits blocked until
`resolveStructuralBreak` (`:297`). With the recommended 24h timelock, that is at least a day of
downtime even if the price has recovered. Operational: document it in the runbook.

**R2-5 Low: thin-pool residual.**
Two-phase breaks assume corrective flow arrives within the window. In a pool with no active
arbitrageur, a genuine oracle gap still confirms and draws down. Run an arbitrage keeper per pool.

**R2-6 Low: rebate on requested input, not settled input.**
`WoolFiSwapRouter.sol:103-105` discards the settled `amountIn`, and `recordSwap` uses the
requested amount. In a thin pool with a sqrt-price-limit partial fill this over-rebates.
Bounded by the weekly cap and funding.
Fix: pass the settled amount.

## Checked and safe

- Multiple swaps per tx or across pools: the snapshot is per pool id and cleared in `afterSwap`
  (`:692-704`). Each swap is guarded individually, so stepping just under the threshold and then
  across reverts. Pools do not share drift.
- Swap plus confirm in the same block: no swap can flag a break (guard), and detection starts a
  window of at least 1h. Impossible.
- Stale break state: `_flagBreakIfReached` resets `confirmed`; `Cleared` and `Resolved` reset
  `detectedAt` and `confirmed` (`:657`). Re-flagging is blocked while broken. A drawdown happens at
  most once per break.
- Weekend `getLastValidPrice`: the guard only rejects moves away from fair that cross the
  threshold, so corrective flow is never blocked. Pause, sequencer and invalid-round checks still
  revert in every adapter, and DualOracleAdapter still enforces the deviation check.
- `lastSwapFeeBps` spoofing: the router's own swap overwrites the slot right before `recordSwap`,
  the value is capped at the base fee, and foreign pools are unconfigured.
- Stuck breaks from pause or stale oracle: confirm reverts, the break persists, and it resumes when
  the oracle recovers. Only R2-1 makes it permanent.
- `RebalanceKeeper.keep`: confirm sits in try/catch; a fresh detection cannot confirm in the same
  call.
- `withdrawUnreserved` is bounded by balance minus liability. Two-step ownership on all four
  contracts is correct.
