# Test Coverage

`MULTISIG=0x...dEaD forge coverage --ir-minimum --report summary --no-match-path "test/fork/**"` on
2026-10-13, after the Review 3 fixes (invariant suites included at the default profile).
`--ir-minimum` is needed because coverage disables the optimizer. Under it, the legacy
`STRANDMainnet.test_votes_historicalSnapshotAtPastBlock` fails (`ERC5805FutureLookup`, a via-IR
`block.number` caching artifact); it passes in normal runs and STRAND is not in the launch path.

| Contract | Lines | Branches | Branches (2026-10-07) |
|---|---|---|---|
| UrufuFeeRebateDistributor | 100% (80/80) | 100% (26/26) | 100% (23/23) |
| WoolFiLiquidityZapper | 100% (89/89) | 100% (29/29) | 100% (29/29) |
| RebalanceKeeper | 100% (18/18) | **100% (8/8)** | 50.0% (4/8) |
| WoolFiSwapRouter | 100% (42/42) | 90.0% (9/10) | 88.9% (8/9) |
| WoolFiHook | 95.9% (378/394) | **88.0% (95/108)** | 80.0% (68/85) |
| WoolFiPositionManager | 97.6% (165/169) | 88.6% (31/35) | 87.9% (29/33) |
| WoolFiUnderwritingVault | 100% (100/100) | 90.9% (20/22) | 90.0% (18/20) |
| WoolFiGovernor | 93.9% (31/33) | 100% (1/1) | n/a |
| SpreadMath | 100% (30/30) | 100% (8/8) | 100% |
| LiquidityAmounts | 100% (20/20) | 100% (8/8) | 100% |
| RobinhoodStockOracleAdapter | 96.5% (55/57) | 94.1% (16/17) | 94.1% |
| ChainlinkOracleAdapter | 100% (33/33) | 80.0% (8/10) | 75.0% (9/12) |
| NyseHoursOracle | 100% (89/89) | 55.6% (10/18) | 100% (18/18) |
| MultisigMarketHours | 100% (15/15) | 100% (2/2) | 100% |
| WoolFiPoolAligner | 98.3% (57/58) | 61.1% (11/18) | n/a |
| WoolFiV3Migrator | 98.1% (52/53) | 85.7% (12/14) | n/a |
| WoolFiArbExecutor | 100% (37/37) | 55.6% (5/9) | n/a |
| BaseHook | 33.3% | 0% (unused callbacks) | 0% |

The NyseHoursOracle branch figure differs from 2026-10-07 because that run used the optimized
build, where some branches are merged; line coverage is unchanged at 100%. The one uncovered router
branch is `_settle` with a non-negative input delta, which an exact-input swap cannot produce.

Suites: 583 non-fork tests across 38 suites, 3 invariant suites, plus fork tests against live 4663
under `test/fork/`. Review 3 regression suites: `Review3HookFixes.t.sol`,
`Review3VaultFixes.t.sol`, `Review3PeripheryFixes.t.sol`, `DeployV3MigratorManifest.t.sol`.

## Invariant suites

Default profile 256 runs x depth 50; also run under `FOUNDRY_PROFILE=ci` (1000 runs x depth 100,
100,000 calls per suite). All pass.

**`WoolFiBreakInvariants`** (new). Handler actions: random-size swaps in both directions, oracle
moves wide enough to cross 15%, leg timestamp skew, market open/close toggles, time warps (short
and multi-day), `checkStructuralBreak`, `confirmStructuralBreak` (half the calls jump exactly to
the window boundary), `resolveStructuralBreak`, PM mint/burn, vault stake/requestUnstake/unstake.
The pool runs with a 900s stabilization window and a 300s skew limit, so every swap mode
(asymmetric, closed, stabilizing, skewed, broken) is reached.

| Invariant | Asserts |
|---|---|
| `singleSwapNeverBreaksPool` | no successful swap takes a non-broken pool from inside to at or past the hard threshold while moving away from fair |
| `atMostOneDrawdownPerEpisode` | vault backing drops at most once per break episode |
| `drawdownOnlyViaTimelyConfirmation` | any drop happens only inside `confirmStructuralBreak`, at or after `confirmReadyAt`, with fresh drift still past the threshold |
| `vaultBackingSolvent` | `totalStaked <= STRAND balance`; zero shares means zero backing |
| `feeRoutingConserved` | each realization: vault part == fee x vaultBps, treasury part == fee x treasuryBps, LP part is the remainder; PM balance covers all pending LP fees |
| `breakStateConsistent` | confirmed implies broken; broken implies a cached target and a detection time, and neither exists without a break |

Non-vacuity, measured over 256 runs: 136 break episodes, 1,256 guard reverts, 44 confirmed
drawdowns. `test_handlerReachesConfirmedDrawdown` pins the detect, confirm and single-drawdown path.

**`RebateDistributorInvariants`** (new). Handler acts as router, owner, funder, donor and traders,
and also changes caps, NFT holdings and time. Invariants: liabilities never exceed the funded
balance (both tokens, including a 6-decimal one); `totalLiability` equals the sum of claimables;
accrued minus claimed equals liability; no wallet exceeds its weekly cap.

**`WoolFiInvariants`** (existing): `pmSharesBackPosition`, `pmShareAccounting`, `vaultSolvent`,
`vaultShareAccounting`, `structuralBreakTargetStateIsConsistent`.

## Guard boundary fuzz

`test/integration/WoolFiGuardBoundary.t.sol`, `testFuzz_guardRevertsExactlyWhenSwapCrossesThreshold`
fuzzes the pre-drift (fair in 0.87 to 1.15), the swap size (1e15 to 4e19 on 100e18 liquidity), the
direction and the mode (open, closed, stabilizing, skewed). It replays each swap from a snapshot
with the threshold raised to 100% to measure the true post-drift, then asserts the guarded swap
reverts with `SwapWouldBreakPool(pre, post)` exactly when post crosses 15% and moves away from
fair, with the same pre and post values. Pinned cases cover adversarial crossings in every mode and
show corrective swaps are always allowed.

## Spec mechanic to test map

| Spec | Mechanic | Tests |
|---|---|---|
| 4 | Asymmetric fee, in-band flat | `WoolFiHook.t.sol` swap_outOfBand_*, swap_inBand_isFlat; `SpreadMath.t.sol` |
| 4 | Full-range only, in-band deposits | `WoolFiHook.t.sol` testRevert_addLiquidity_notFullRange, _outOfBand |
| 4.1 | Rebates | `WoolFiSwapRouter.t.sol`; `UrufuFeeRebateDistributor.t.sol` (every branch: caps, uint192 boundary, week rollover at the exact second, funding clamps, fee clamp, dust); `RebateDistributorInvariants` |
| 5 | Market hours, flat fee, stale allowed while closed | swap_marketClosed_*; `NyseHoursOracle.t.sol` (all 20 holidays, DST edges, table exhaustion after 2030, early-close limitation, governance reverts, fuzzed session shape) |
| 5 | Oracle fail-closed, pause, sequencer | `RobinhoodStockOracleAdapter.t.sol`; swap_whenOracleStale; fork stockOraclePausedRevertsSwaps |
| 5 | Timestamp skew | oracleSkew_* incl. fuzz boundary; break invariants skew action |
| 6 | Cached fair, corrective only | structuralBreak_isCorrectiveOnly_usesCachedFair_thenResolves, correctionCanCrossFair |
| 6 | Two-phase break, drawdown once | `WoolFiBreakInvariants` (b), (c); structuralBreak_* ; fork structuralBreakAndDrawdown |
| 6 | Single-swap guard, all modes | `WoolFiGuardBoundary.t.sol` fuzz; `WoolFiBreakInvariants` (a); testRevert_swap_singleSwapWouldBreakPool |
| 6 | Stabilization | stabilization_* |
| 6 | Permissionless detection | checkStructuralBreak_*; `RebalanceKeeper.t.sol` |
| 7 | PM shares and fee realization | `WoolFiPositionManager.t.sol`; invariants pm*, feeRoutingConserved |
| 7 | Zapper | `WoolFiLiquidityZapper.t.sol` (every branch: native ETH wrap and refund, third-token refund as ETH, fee-on-transfer input, plan validation, donations not swept); fork zapUsdgToMstrUsdgLp |
| 8 | Fee routing 65/20/15, cooldown, claim window | `WoolFiPositionManager.t.sol`, `WoolFiUnderwritingVault.t.sol`; `feeRoutingConserved`; fork fullLifecycle |
| 8 | Two-step governance | `WoolFiGovernor.t.sol`, hook proposeGovernor_* |

## Gaps

- Rebate farming across wallets (M-2) is bounded only per wallet by design; no test models a
  Sybil set beyond showing per-wallet caps hold.
- Aligner and arb-executor branch coverage (61% / 56%) is the lowest of the launch-path contracts;
  their uncovered branches are mostly clamping and early-exit paths.
- `DualOracleAdapter` is legacy and not in the launch path; coverage left as is.
