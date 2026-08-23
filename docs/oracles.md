# WoolFi Oracle Stack

**Status:** Robinhood production design; read with [`PROJECT_SPEC.md`](../PROJECT_SPEC.md) §5.

Oracle safety is load-bearing because WoolFi uses fair value to choose the fee applied to every
swap. The production target is Robinhood Chain (4663); no production adapters are deployed yet.

## Pool-class fair value

- **Stock/USDG spot:** stock/USD divided by USDG/USD.
- **Stock/WETH crypto beta:** stock/USD divided by WETH/USD.
- **Stock/stock relative value:** the two stock/USD prices divided in pool token order.
- **WETH/USDG always-open spot:** WETH/USD divided by USDG/USD.

All adapter outputs use 1e18 normalization. Pool token address ordering determines whether the
ratio is used directly or inverted.

## Current interfaces

`IPriceOracle.getPrice()` returns a WAD price and reverts on invalid or stale data.
`IMarketHoursOracle.isMarketOpen()` identifies equity-hours pools. An address-zero market-hours
oracle denotes an always-open pool.

`IPriceOracle.getPriceData()` returns the same WAD price plus the source `updatedAt`.
`IPriceOracle.requireRuntimeGuards()` enforces sequencer, pause, and last-print validity without
treating heartbeat age as a failure. `IMarketHoursOracle.currentSessionStart()` supplies the
session boundary used by post-open stabilization.

## Current adapters

### `RobinhoodStockOracleAdapter`

This is the production-shaped stock-leg adapter already present in code. Before returning a price,
it verifies:

- the sequencer uptime answer indicates up;
- sequencer timestamps are nonzero and not in the future;
- the post-recovery grace period has elapsed;
- the Robinhood Stock Token reports `oraclePaused() == false`;
- the Chainlink round has a positive answer, a valid round relationship, and a valid timestamp;
- feed age does not exceed twice the configured heartbeat.

Any failure reverts. One independently verified adapter is required for every stock leg; an adapter
address in a dry run is not a deployment.

### `ChainlinkOracleAdapter`

The generic adapter normalizes a Chainlink feed, rejects nonpositive values, and reverts when the
feed exceeds its configured freshness bound. It remains suitable for non-stock legs only after the
Robinhood feed proxy, decimals, and heartbeat are verified.

### `DualOracleAdapter`

The legacy generic dual-source wrapper can return the primary when sources agree, fail over when
only one source succeeds, and revert on excessive deviation or two failures. Timestamp skew is
enforced by the hook across the two pool legs, not inside this adapter. Both legs still expose
`getPriceData()` and `requireRuntimeGuards()`.

### Market-hours adapters

`NyseHoursOracle` and `MultisigMarketHours` remain available implementation artifacts. The selected
production source and calendar configuration must be reviewed for every stock-linked pool.
WETH/USDG uses no market-hours gate.

## Required failure behavior

Open-market swaps and liquidity additions hard-revert when:

- either required leg is stale, invalid, incomplete, or future-dated;
- a Robinhood stock-token oracle is paused;
- the sequencer is down, has invalid status data, or is inside the recovery grace period;
- a required adapter or feed is missing.

Closed-market and stabilization paths still hard-revert on pause, sequencer, and invalid last-print
failures via `requireRuntimeGuards()`. They do not treat heartbeat staleness as a failure.

When `maxOracleSkew` is set, excessive two-leg timestamp skew degrades swaps to the flat base fee
and hard-reverts new liquidity. Stale, paused, invalid, and sequencer-unsafe feeds never degrade
into that mode; they revert.

## Structural-break pricing

The hook caches the fair price that triggered the break (`cachedFairPriceWad`) and admits only
swaps that reduce drift against that cached value. The target does not silently follow a moving
oracle while the pool is contained. A configurable post-open stabilization interval, measured from
`currentSessionStart()`, keeps asymmetric operation off until the session has settled. Always-open
pools ignore that interval.

## Per-pool launch record

For each of the exact 18 pools, record and independently approve:

- token0/token1 and decimals;
- adapter addresses and underlying feed proxies;
- feed decimals, heartbeat, and maximum dual-leg timestamp skew;
- stock-token `oraclePaused()` behavior where applicable;
- sequencer feed and recovery grace period;
- market-hours source/calendar, or always-open designation;
- fair-price orientation and an expected-value test vector;
- fork-test block and result;
- multisig approval reference.

All feeds and adapters must be ready before any pool is marked live. No placeholder or invented
address may enter the production manifest.
