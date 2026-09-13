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

- the Robinhood Stock Token reports `oraclePaused() == false`;
- the Chainlink round has a positive answer, a valid round relationship, and a valid timestamp;
- feed age does not exceed twice the configured heartbeat;
- when a sequencer uptime feed is configured (constructor sequencer address non-zero and grace
  period non-zero): the sequencer uptime answer indicates up, sequencer timestamps are nonzero
  and not in the future, and the post-recovery grace period has elapsed.

Any failure reverts. `sequencerEnabled` is an immutable public view derived from the constructor
inputs. A half-configured pair (feed set with grace period zero, or vice versa) reverts at deploy
time with `IncompleteSequencerConfig` or `ZeroGracePeriod`. On Robinhood Chain (4663) both are
zero at launch (see §5.1 and "Sequencer safety" below).

One independently verified adapter is required for every stock leg; an adapter address in a dry
run is not a deployment.

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
- a required adapter or feed is missing;
- the sequencer is down, has invalid status data, or is inside the recovery grace period —
  when a sequencer uptime feed is configured on the adapter.

Closed-market and stabilization paths still hard-revert on pause, invalid last-print, and (when
configured) sequencer failures via `requireRuntimeGuards()`. They do not treat heartbeat
staleness as a failure.

When `maxOracleSkew` is set, excessive two-leg timestamp skew degrades swaps to the flat base fee
and hard-reverts new liquidity. Stale, paused, invalid, and sequencer-unsafe feeds never degrade
into that mode; they revert.

## Sequencer safety on Robinhood Chain

Robinhood Chain (4663) publishes no L2 Sequencer Uptime Feed, and [Chainlink has stated](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
it is not expanding that product to new networks. The stock adapter is deployed with
`sequencerUptimeFeed == address(0)` and `gracePeriod == 0` on 4663, which disables the sequencer
guard at construction. `oraclePaused()` and price-freshness enforcement remain in force. See
`PROJECT_SPEC.md` §5.1 for the disclosed operator-trust assumption; the same disposition applies
to `ChainlinkOracleAdapter` (WETH/USDG), which never called a sequencer feed in the first place.

If a compatible sequencer uptime feed is later published on 4663, governance may redeploy the
affected adapters with the guard enabled. Doing so requires a new adapter instance per pool leg
and a governor pool-oracle rebinding step.

## Chainlink feed inventory on Robinhood Chain

Source: `https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json` (the JSON
Chainlink docs load their address tables from). All Robinhood Chain feeds share `decimals = 8`,
`heartbeat = 86400s`, `deviation = 50 bps`, and are SVR-enabled. Stock feeds report a Total
Return Value (`underlying × uiMultiplier()`); corporate actions are surfaced through the token
contract's `oraclePaused()`. Every address below must be re-verified on-chain immediately before
adapter deployment.

| Symbol | Chainlink proxy on 4663                        | Notes |
|--------|-----------------------------------------------|-------|
| MSTR   | `0x396118bdFB181e6240E74D243F266B061c0edc3D` | Robinhood MSTR/USD, TRV, us_equities_24/5 |
| COIN   | `0xA3a468A452940B7D6b69991207B508c609a98Ef2` | Robinhood COIN/USD, TRV, us_equities_24/5 |
| CRCL   | `0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a` | Robinhood CRCL/USD, TRV, us_equities_24/5 |
| NVDA   | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | Robinhood NVDA/USD, TRV, us_equities_24/5 |
| SPY    | `0x319724394D3A0e3669269846abE664Cd621f9f6A` | Robinhood SPY/USD, TRV, us_equities_24/5 |
| QQQ    | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` | Robinhood QQQ/USD, TRV, us_equities_24/5 |
| PLTR   | `0x820ABedFF239034956B7A9d2F0a331f9F075eB4c` | Robinhood PLTR/USD, TRV, us_equities_24/5 |
| AAPL   | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | Robinhood AAPL/USD, TRV, us_equities_24/5 |
| TSLA   | `0x4A1166a659A55625345e9515b32adECea5547C38` | Robinhood TSLA/USD, TRV, us_equities_24/5 |
| MSFT   | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` | Robinhood MSFT/USD, TRV, us_equities_24/5 |
| WETH   | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | Registered as ETH/USD; WETH ↔ ETH is 1:1 by contract. Document the alias in the launch record. `ChainlinkOracleAdapter`, not stock-guarded. |
| USDG   | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | USDG/USD, crypto category, always-open. `ChainlinkOracleAdapter`. |
| Sequencer uptime | **not published on 4663**            | Adapter deploys with the sequencer guard disabled; see above. |

GLD and SLV were removed from the launch catalog (spec §3) because Chainlink does not publish
GLD/USD on 4663. Re-adding those pools would require a future spec revision that binds them to
verified feeds — do not fabricate a GLD address or launch a partial catalog.

## Structural-break pricing

The hook caches the fair price that triggered the break (`cachedFairPriceWad`) and admits only
swaps that reduce drift against that cached value. The target does not silently follow a moving
oracle while the pool is contained. A configurable post-open stabilization interval, measured from
`currentSessionStart()`, keeps asymmetric operation off until the session has settled. Always-open
pools ignore that interval.

## Per-pool launch record

For each of the exact 16 pools, record and independently approve:

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
