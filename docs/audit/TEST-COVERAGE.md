# Test Coverage

`forge coverage --report summary` (fork and invariant tests excluded) on 2026-10-06:

| Contract | Lines | Branches |
|---|---|---|
| WoolFiHook | 99.6% | 90.5% |
| WoolFiPositionManager | 98.1% | 87.9% |
| WoolFiUnderwritingVault | 100% | 90.0% |
| WoolFiGovernor | 100% | n/a |
| WoolFiSwapRouter | 94.4% | 66.7% |
| WoolFiLiquidityZapper | 90.5% | 39.3% |
| UrufuFeeRebateDistributor | 100% | 26.3% |
| RebalanceKeeper | 100% | 100% |
| SpreadMath | 100% | 100% |
| LiquidityAmounts | 100% | 100% |
| RobinhoodStockOracleAdapter | 100% | 93.8% |
| ChainlinkOracleAdapter | 100% | 77.8% |
| NyseHoursOracle | 88.8% | 55.6% |
| MultisigMarketHours | 100% | 100% |
| BaseHook | 33.3% | 0% (unused callbacks) |

Weakest branch coverage: rebate distributor, zapper, NyseHoursOracle, router.

Suites: 350 deterministic tests, 5 invariants (`pmSharesBackPosition`, `pmShareAccounting`,
`vaultSolvent`, `vaultShareAccounting`, `structuralBreakTargetStateIsConsistent`), 20 fork tests
against live 4663 (19 pass, 1 Base-only skip).

## Spec mechanic to test map

| Spec | Mechanic | Tests |
|---|---|---|
| 4 | Asymmetric fee, in-band flat | `WoolFiHook.t.sol` swap_outOfBand_*, swap_inBand_isFlat; `SpreadMath.t.sol` |
| 4 | Full-range only, in-band deposits | `WoolFiHook.t.sol` testRevert_addLiquidity_notFullRange, _outOfBand |
| 4.1 | Rebates | `WoolFiSwapRouter.t.sol`, rebate cases; branches thin |
| 5 | Market hours, flat fee, stale allowed while closed | swap_marketClosed_*, addLiquidity_marketClosed; `NyseHoursOracle.t.sol`; fork nyseHoursOracleClosedWeekend |
| 5 | Oracle fail-closed, pause, sequencer | `RobinhoodStockOracleAdapter.t.sol`; swap_whenOracleStale; fork stockOraclePausedRevertsSwaps |
| 5 | Timestamp skew | oracleSkew_* incl. fuzz boundary |
| 6 | Cached fair, corrective only | structuralBreak_isCorrectiveOnly_usesCachedFair_thenResolves, correctionCanCrossFair |
| 6 | Drawdown, drawdown revert persists break | structuralBreak_triggersVaultDrawdown, persistsWhenDrawdownReverts; fork structuralBreakAndDrawdown |
| 6 | Single-swap guard | testRevert_swap_singleSwapWouldBreakPool, swap_belowHardThreshold_succeedsWithGuard, correctiveSwap_duringBreak_notBlockedByGuard |
| 6 | Stabilization | stabilization_* |
| 6 | Permissionless detection | checkStructuralBreak_* ; `RebalanceKeeper.t.sol` |
| 7 | PM shares and fee realization | `WoolFiPositionManager.t.sol`; invariants pm* |
| 7 | Zapper | `WoolFiLiquidityZapper.t.sol`; fork zapUsdgToMstrUsdgLp |
| 8 | Fee routing 70/20/10, URU cap, cooldown | `WoolFiPositionManager.t.sol`, `WoolFiUnderwritingVault.t.sol`; fork fullLifecycle |
| 8 | Two-step governance | `WoolFiGovernor.t.sol`, hook proposeGovernor_* |

## Gaps

- No test for H-1 (guard bypass through flat-fee modes) or M-1.
- No test for rebate farming across wallets (M-2).
- No invariant that routed fee parts sum to the realized fee.
