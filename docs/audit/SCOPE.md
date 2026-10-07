# Audit Scope

Prepared 2026-10-06 as an internal pre-audit package. Not a substitute for an external audit.

## Commit

- Base commit: `aea015b4ec69d31695e8fd6f3bf4dbe8567b013e`
- Uncommitted at time of writing: `src/WoolFiHook.sol` (+60/-1, single-swap break guard using
  transient storage). Freeze and re-hash before handing to auditors.

## Toolchain

- solc 0.8.26, `evm_version = cancun` (transient storage required), optimizer on, 800 runs,
  `via_ir = false`.
- Uniswap v4-core v4.0.0, OpenZeppelin Contracts v5.6.1, Solady v0.1.26, Chainlink brownie
  contracts 1.3.0, forge-std v1.16.1 (from `foundry.lock`).
- Target chain: Robinhood Chain (4663), Arbitrum Orbit.

## In scope (production contracts)

| File | Lines |
|---|---|
| src/WoolFiHook.sol | 670 |
| src/WoolFiPositionManager.sol | 473 |
| src/WoolFiUnderwritingVault.sol | 236 |
| src/WoolFiLiquidityZapper.sol | 211 |
| src/UrufuFeeRebateDistributor.sol | 145 |
| src/WoolFiSwapRouter.sol | 140 |
| src/WoolFiGovernor.sol | 93 |
| src/RebalanceKeeper.sol | 39 |
| src/lib/SpreadMath.sol | 155 |
| src/lib/LiquidityAmounts.sol | 66 |
| src/base/BaseHook.sol | 224 |
| src/oracle/RobinhoodStockOracleAdapter.sol | 136 |
| src/oracle/ChainlinkOracleAdapter.sol | 82 |
| src/oracle/NyseHoursOracle.sol | 241 |
| src/oracle/MultisigMarketHours.sol | 48 |
| src/interfaces/*.sol | 83 |
| src/periphery/WoolFiPoolAligner.sol | 133 |

Total in scope: about 3,170 lines.

`WoolFiPoolAligner` is in scope because 16 of the 18 pools launch with zero liquidity and the
aligner is the path that keeps them on the oracle price (PROJECT_SPEC.md section 9.1). It is
ownerless and custody-free; review focus is the zero-delta invariant, the sqrtPrice conversion, and
its interaction with every hook mode, including the break-state hop through the cached target.

## Out of scope

- `src/STRAND.sol`, `src/STRANDMainnet.sol`, `src/testnet/`: legacy, not deployed on 4663.
  Recommend moving them out of `src/` before the audit so they are not billed.
- `src/oracle/DualOracleAdapter.sol`: not used by the Robinhood deployment path.
- `src/mocks/`, `test/`, `script/`, `frontend/`, `indexer/`, `keeper/`.
- Uniswap v4 PoolManager, Chainlink feeds, Robinhood Stock Token contracts, URU, Safe.

## Specification

`PROJECT_SPEC.md` sections 4 to 8 define intended behavior. Deviations found during review are
listed in `KNOWN-ISSUES.md`.
