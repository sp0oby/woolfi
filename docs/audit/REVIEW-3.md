# Review 3: adversarial pass after the timelock and unstake changes

Internal review, 2026-10-13, of commit `5dfa3e6` plus the frontend. Four parallel reviewers
(hook and position manager; vault and governance, covering commit `429dfe0`; periphery,
including the previously out-of-scope `WoolFiV3Migrator` and `WoolFiArbExecutor`; frontend). Every
finding below was reproduced with a proof-of-concept test before being fixed; the PoCs are now
permanent regression tests that assert each attack fails. Not a substitute for an external audit.

## Status

| ID | Severity | Finding | Fix |
| --- | --- | --- | --- |
| H-1 | High | Break-mode swaps were only direction-checked. One transaction could overshoot the cached target, call `confirmStructuralBreak` to seize `drawdownBps` of the vault, and swap back (cost ~0.035% of pool value); the reverse cleared a genuine break with no drawdown. | A break-mode swap may not end further from the cached target than it started, or than `toleranceBps` when it started closer (`BreakSwapOvershoot`). `confirmStructuralBreak` and `clearRecoveredBreak` revert in the same second as a break-mode swap (`BreakSwapThisBlock`); only break-mode swaps write that timestamp. |
| V-1 | High | A matured unstake request never expired, so stakers held a free option to exit during an overnight or weekend gap that could not yet be flagged, leaving the drawdown to everyone else. | Requests lapse 1 day after maturing (`UNSTAKE_CLAIM_WINDOW`, `UnstakeRequestExpired`). `isBreakPendingForVault` also reports a gap past the hard threshold against the last valid prices while the pool cannot be flagged (market closed, stabilizing, skewed); it never reverts. |
| F1 | High | The dapp sent transactions on whatever chain the wallet was on (wagmi keeps `useChainId()` at the only configured chain; writes without `chainId` skip viem's chain check). | Every write passes `chainId: 4663`; actions are disabled and a switch prompt shown while the wallet's own chain differs. |
| V-2 | Medium | A governance change queued during a pending break (e.g. `setVault` to 99.99% drawdown) could execute against stakers locked by that break. | `setVault`, `updatePoolConfig(V2)`, `setPoolSafety` and `setBreakConfirmSeconds` revert `BreakPendingForPool` while a break is pending and in the block of a `resolveStructuralBreak`. |
| V-3 | Medium | Reward accumulators used 1e18 precision, so 6-decimal (USDG) rewards truncated to zero at realistic share supplies and stayed stuck (vault and position manager). | `ACC_PRECISION` 1e36 with `fullMulDiv`; reward debt rounds up so total payouts never exceed deposits. |
| P-1 | Medium | A Urufu Gemu holder who was also the pool's main LP could wash-trade through their own liquidity and collect rebates above the protocol cut. | Each rebate is capped at the pool's treasury cut (`rebateBpsFor`); the default treasury cut is 15%, matching the advertised rebate. |
| M/L-2 | Low/Medium | A confirmation window longer than a trading session meant equity-pool breaks could never be confirmed, keeping unstakes locked. | Equity-hours pools: confirmation plus stabilization ≤ 3.5 hours (`MAX_EQUITY_BREAK_WINDOW`). |
| F2, F4 | Medium | Swap and deposit could submit with a quote or preview from previous inputs (after a direction flip, minimum output ≈ 0). | Quotes and previews are keyed to the inputs that produced them; actions wait for a matching one. Also applied to the zap quote. |
| F3 | Medium | Migrate could submit with zero minimums while its estimate was loading. | Migrate requires a successful estimate. |
| F10 | Medium (ops) | Next.js 14.2.18 (end of life, advisories). | Upgraded to 14.2.35. |
| V-4 | Low | A staker with a small pending request could need ~4 days to fully exit, longer than the timelock. | A new request replaces the pending one. |
| V-5 | Low | One vault wired to two pools let the first pool's break stop locking it. | `setVault` rejects a vault mapped to another pool (`VaultAlreadyMapped`). |
| L-3 | Low | `ChainlinkOracleAdapter` accepted future-dated rounds. | Rejects `updatedAt == 0` or in the future. |
| L-4 | Low | Anyone could initialize an authorized pool at any price. | Initialization must be within `toleranceBps` of the oracle fair price (`InitialPriceOutOfBand`). |
| F8 | Low | No minimum amounts or deadline on LP withdrawal; no deadline on router swaps. | New `burn(key, shares, amount0Min, amount1Min, deadline, to)` and `swap(..., deadline)` overloads, used by the frontend. |
| F5-F7, F9 | Low | Approval state could be stale; slippage accepted up to 50%; stake shown in shares; no security headers. | Approvals tracked by token, spender and amount; slippage capped at 5% with a warning above 1%; stake shown in URU; CSP, frame denial, HSTS and related headers. |
| P-3 | Low | `DeployV3Migrator` did not check `POSITION_MANAGER` against the manifest. | Checked when the manifest value is set. |

Follow-on changes: `WoolFiPoolAligner` clamps its target to within `toleranceBps - 1` of the cached
target during a break (its old hop through the target is exactly what H-1 now forbids); the keeper
treats `BreakSwapThisBlock` as idle.

## Accepted residuals

- **L-5, LP mint price limit.** `mint` has no explicit price bound. Deposits only succeed in band
  (±`toleranceBps`), so a sandwich is bounded by the band; Robinhood Chain has no public mempool.
  Adding a bound would change the `mint` ABI used by the zapper, migrator, scripts and frontend.
- **Break-mode dust swaps.** Anyone can make a tiny corrective swap every second to delay
  `confirmStructuralBreak` / `clearRecoveredBreak`. Each swap must be corrective and costs gas and
  fees; the keeper retries every tick.
- **Pause and gap.** A paused hook with an unflagged gap does not count as pending, deliberately:
  otherwise the instant guardian pause could lock stakers behind the 3-day unpause.
- **Holiday-weekend gap.** An unflaggable gap locks unstakes but does not block governance; only a
  flagged break does. A holiday weekend can outlast the 3-day timelock.
- **Lapsed request during a lock.** If a break lock outlasts a staker's 1-day withdrawal window,
  the request lapses and must be renewed (another 2-day cooldown).
- **Requested shares still earn rewards.** With the 1-day claim window the exit option is
  available at most one day in three, so rewards were not restructured.
- **Rebates need a treasury cut.** A pool whose treasury sink is unset earns no rebates.

## Checked and found sound

Single-swap guard in live, closed, stabilizing and skewed modes; transient-storage snapshots (no
leakage between swaps or pools); hook-to-position-manager reentrancy; position-manager fee
accounting and non-transferable shares (no first-depositor or inflation attack); SpreadMath and
LiquidityAmounts; stock adapter staleness, pause and timestamp checks; `NyseHoursOracle` calendar
logic; vault share math and drawdown bounds; `TimelockController` roles and admin; ownership
handoff ordering; guardian scope; rebalancer checks; `RebalanceKeeper`; the v3 migrator's custody
of user NFTs (owner check, snapshots, refunds, approval reset); zapper approvals and routes;
router settlement; aligner (empty pools only, zero delta); arb executor; frontend recipients,
exact approvals, address sources and XSS surface.

Also confirmed: Robinhood Chain runs ArbOS 61 (`arbOSVersion()` = 116), so EIP-1153 transient
storage is available.

Regression tests: `test/integration/Review3HookFixes.t.sol`, `Review3VaultFixes.t.sol`,
`Review3PeripheryFixes.t.sol`, `test/unit/DeployV3MigratorManifest.t.sol`, plus additions in
`ChainlinkOracleAdapter.t.sol` and `WoolFiPoolAligner.t.sol`.
