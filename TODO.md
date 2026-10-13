# WoolFi Build TODO

The canonical production design is [`PROJECT_SPEC.md`](./PROJECT_SPEC.md). This file tracks the
remaining work toward the coordinated Robinhood Chain launch; completion boxes do not override
the spec.

## Canonical specification

- [x] Make `PROJECT_SPEC.md` canonical for WoolFi by Urufu Labs on Robinhood Chain 4663.
- [x] Lock the exact 18-pool catalog (GLD/USDG and GLD/SLV briefly removed, then restored once
      Chainlink published `GLD / USD` on 4663).
- [x] Define stock/USDG spot, stock/WETH crypto-beta, stock/stock relative-value, and always-open
      WETH/USDG behavior.
- [x] Replace production STRAND assumptions with externally supplied URU underwriting.
- [x] Record all-18-or-no-launch policy and resumable/non-atomic broadcast semantics.
- [x] Add `seedSet` (`weth-usdg`, `nvda-usdg`): all 18 deploy, only the seed set is seeded.
- [x] Mark production deployment state honestly: no live WoolFi contracts or pools.
- [x] Specify planned break containment, stabilization, timestamp-skew, and hard-revert semantics.

## Safety mechanisms required before production

- [x] Cache fair value when a structural break is triggered.
- [x] During a break, allow only swaps proven corrective against cached break fair.
- [x] Add a post-open stabilization period before asymmetric operation/break resolution.
- [x] Expose source timestamps and enforce maximum two-leg timestamp skew.
- [x] Ensure stale, paused, invalid, and sequencer-unsafe states hard-revert every fair-value path.
- [x] Ensure closed-market flat-fee handling cannot bypass sequencer safety.
- [x] Add unit, fuzz, integration, invariant, and Robinhood fork coverage for each mechanism.
- [x] Reconcile events, indexer schema, frontend modes, and keeper behavior with the final semantics.

## Shared production infrastructure

- [x] Internal adversarial Review 3 (2026-10-13): 3 High, 6 Medium and several Low findings fixed
      with regression tests ([`docs/audit/REVIEW-3.md`](./docs/audit/REVIEW-3.md)).
- [ ] Freeze and audit the hook, position manager, vault, governor, router, adapters, scripts, and
      now also `WoolFiV3Migrator` (and `WoolFiArbExecutor` if deployed). Audit the code as fixed in
      Review 3; the earlier internal audit package predates those fixes.
- [ ] Manually test wallet connection (RainbowKit / WalletConnect) on a production build under the
      new Content-Security-Policy, with a real WalletConnect project id.
- [x] Wire and verify the position manager on the hook.
- [x] Configure and test the swap router end to end.
- [x] Configure the indexer for all 18 pools, vaults, and production start blocks.
- [x] Configure, exercise, and monitor the permissionless keeper.
- [ ] Create the production multisig; verify signers, threshold, recovery, and handoff.
      Recommended: 3-of-5 Safe ([`docs/launch-decisions.md`](./docs/launch-decisions.md) #1).
- [x] Build the governance timelock: `TimelockController` (3 days, no admin), guardian-only instant pause
      on `WoolFiGovernor`, `script/DeployTimelock.s.sol`, Safe handoff batches from
      `script/TimelockHandoff.s.sol`, tests in `test/integration/WoolFiTimelock.t.sol`.
- [ ] Deploy the timelock after the Safe exists and execute both handoff batches (3 days apart).
- [ ] Choose the vault rebalancer: a second Safe with different signers or a rebalance executor
      contract; never the production Safe or the timelock. Recommended: a second 2-of-3 Safe
      ([`docs/launch-decisions.md`](./docs/launch-decisions.md) #2).
- [x] Publish monitoring, incident-response, and rollback/containment runbooks.
- [ ] Establish the production security-reporting and bug-bounty process (paid bounty / Immunefi).
- [ ] Name monitoring owners, alert destinations, and thresholds (runbooks are templates only).
- [x] Keeper exits non-zero on failed simulations (`KEEPER_FAIL_ON_ERROR`) and posts failures to
      `KEEPER_ALERT_WEBHOOK`.
- [ ] Add keeper health metrics (last successful tick) for uptime monitoring.
- [ ] Add indexer health/lag alerts; do not rely on the frontend stale check alone (it now reads
      Ponder `/status`, so lag is measurable).

## Oracle and feed verification

Chainlink is the official Robinhood Chain source. Do not invent feed addresses.

- [x] Resolve live Chainlink proxy, decimals, heartbeat, and deviation for every catalog asset
      from the Chainlink Robinhood directory. **All 14 catalog assets covered** (GLD restored
      once Chainlink published `GLD / USD`); inventory in `docs/oracles.md`. All feeds are 8 decimals, 86400s
      heartbeat, 50 bps deviation. Re-verify on-chain before each adapter deploy.
- [x] Resolve the GLD/USD gap - Chainlink now publishes `GLD / USD` on 4663
      (`0x470A51258068043bd43dC0a56245625C9fE86eB0`); GLD/USDG and GLD/SLV restored (spec §3).
- [x] Resolve the L2 sequencer uptime feed for chain 4663 - none is published; adapter now
      accepts `sequencerUptimeFeed == address(0) + gracePeriod == 0` as an explicit opt-out, and
      spec §5.1 discloses the operator-trust assumption.
- [ ] Document WETH ↔ ETH/USD alias in the launch record (`0x78F3...` is registered ETH/USD;
      WETH ↔ ETH is 1:1 by contract).
- [ ] Decide the production market-hours source (`NyseHoursOracle` vs `MultisigMarketHours`) and
      bind it for every equity pool. Recommended: `NyseHoursOracle`, early-close days marked as
      holidays ([`docs/launch-decisions.md`](./docs/launch-decisions.md) #5).
- [ ] Deploy one `RobinhoodStockOracleAdapter` per stock/ETF leg (with sequencer disabled) and
      one `ChainlinkOracleAdapter` per WETH/USDG leg, pointed at verified proxies.
- [x] Add Robinhood fork tests that read each production feed through those adapters (price
      band, decimals, heartbeat, `oraclePaused()`) - `test/fork/WoolFiPreDeploy.fork.t.sol`
      covers all 10 stock adapters + WETH/USDG + full-stack authorize on real 4663 state; runs
      when `ROBINHOOD_RPC_URL` is set, skips cleanly otherwise.
- [x] Harden `ChainlinkOracleAdapter` with round-completeness (`answeredInRound`) matching the
      stock adapter.
- [x] Decide whether WETH/USDG should also check the sequencer - moot: no sequencer feed on
      4663 for either adapter; both deploy with sequencer disabled and rely on the disclosed
      operator-trust assumption.
- [ ] Decide whether stock/USDG and stock/WETH pools get a positive `maxOracleSkew` (today only
      spread pools require it; default is 0). Recommended: keep 0
      ([`docs/launch-decisions.md`](./docs/launch-decisions.md) #6).
- [ ] Record the per-pool launch-record fields in `docs/oracles.md` (feeds, heartbeats, skew,
      hours, expected-value test vectors) - Chainlink inventory landed; per-pool orientation and
      test vectors still to fill.

## Per-pool readiness - exact 18

For every pool below, verify token contracts, oracle adapters, feed proxies, heartbeat/skew limits,
sequencer and market-hours settings, fair-price orientation, risk parameters, URU cap, initial
price, initial liquidity, indexer metadata, and smoke tests.

- [ ] MSTR/USDG
- [ ] COIN/USDG
- [ ] CRCL/USDG
- [ ] NVDA/USDG
- [ ] SPY/USDG
- [ ] GLD/USDG
- [ ] AAPL/USDG
- [ ] TSLA/USDG
- [ ] MSTR/WETH
- [ ] COIN/WETH
- [ ] QQQ/WETH
- [ ] NVDA/WETH
- [ ] PLTR/WETH
- [ ] AAPL/MSFT
- [ ] SPY/NVDA
- [ ] SPY/QQQ
- [ ] GLD/SLV
- [ ] WETH/USDG

## Capital and oracle approvals

- [ ] Approve each per-vault URU cap and aggregate URU treasury cap (sizing rule in
      [`docs/launch-decisions.md`](./docs/launch-decisions.md) #3).
- [ ] Confirm approved URU is available without exceeding either cap.
- [ ] Verify all stock-token pause behavior and all production feed metadata.
- [ ] Verify WETH/USDG feeds and always-open designation.
- [ ] Approve initial liquidity and slippage bounds for the seed set (`weth-usdg`, `nvda-usdg`).
      Recommended: a small, affordable seed in the two seed pools only (outside LPs bring depth),
      100 bps ([`docs/launch-decisions.md`](./docs/launch-decisions.md) #4).
- [x] Enforce seed `slippageBps` on-chain: `SeedInitialLiquidity.s.sol` requires the shares the
      approved amounts mint at the launch `sqrtPriceX96`, less `slippageBps` (max 10%).
- [x] Empty-pool re-peg: `src/periphery/WoolFiPoolAligner.sol` plus keeper align step;
      `test/fork/WoolFiPoolAligner.fork.t.sol` passes live (NVDA/USDG 10% off Chainlink: first mint
      reverts, align at zero cost, first mint succeeds).
- [ ] Deploy `WoolFiPoolAligner` (`script/DeployPoolAligner.s.sol`), record `poolAligner`, and rerun
      the aligner fork test against chain ID 4663 as a launch gate.
- [x] Frontend: call `align` before a first deposit into an empty pool (`frontend/lib/poolAligner.ts`
      `needsAlign`, ABI in `frontend/lib/abis/poolAligner.ts`).
- [ ] Deploy `WoolFiV3Migrator` (`script/DeployV3Migrator.s.sol`) so the Migrate tab works: it is
      how the 16 unseeded pools get their first liquidity. `readiness` now requires
      `manifest.v3Migrator`.
- [ ] Decide URU vault funding policy for unseeded pools (phantom-break drawdown risk, spec 9.1).
      Recommended: no treasury funding until first liquidity
      ([`docs/launch-decisions.md`](./docs/launch-decisions.md) #3).
- [ ] Confirm no placeholder or unverified address is present in production configuration.

## Deploy automation and CI

- [x] Pass `URU_CAP` from each pool's `vaultAllocationCap` in `robinhood_batch_deploy.py`
      (`CreatePool.s.sol` requires it; batch deploy currently omits it).
- [x] Wire `SeedInitialLiquidity.s.sol` into the batch/orchestrator path with approved amounts.
- [x] CI runs `robinhood_batch.py validate` (pre-launch) or `readiness` (once live) against the
      approved config when the `ROBINHOOD_BATCH_CONFIG` and `ROBINHOOD_RPC_URL` secrets are set.
- [ ] Wire receipt verify/reconcile into CI; check frontend/indexer/keeper manifest digest parity.
- [x] Robinhood fork tests run in CI whenever `ROBINHOOD_RPC_URL` is set and skip cleanly when it
      is not.
- [x] Add indexer lockfile (npm), smoke tests, and rebate-distributor vars to `indexer/.env.example`.
- [x] Add `keeper/.env.example`.
- [ ] Add a keeper/manifest integration check.
- [x] Add frontend lint and production-env validation (`NEXT_PUBLIC_INDEXER_URL`, WalletConnect,
      site URL): production builds warn, and fail once the manifest is live.
- [x] Lock `lib/v4-periphery` in `foundry.lock`.
- [ ] Import indexer ABIs from Foundry `out/` instead of hand-maintained copies.

## Deployment and launch

- [ ] Complete Robinhood fork tests and no-broadcast simulations.
- [ ] Record explicit approval immediately before every broadcast, retry, or resume.
- [ ] Reconcile receipts and on-chain state after each non-atomic step.
- [ ] Verify bytecode, constructor arguments, ownership, wiring, pool keys, and start blocks.
- [ ] Populate the production manifest only with receipt-backed deployments.
- [ ] Keep all pools pending and user actions disabled during deployment work.
- [ ] Verify frontend, router, indexer, keeper, monitoring, feeds, and vaults for all 18, and
      seed liquidity for the seed set.
- [ ] Obtain separate final all-18 coordinated go/no-go approval.
- [ ] Launch none if any pool or shared requirement is incomplete.

## Frontend accuracy (before public launch)

- [x] Remove the cumulative “Recent fees” stat (it lived in unused dashboard components, now deleted).
- [x] Make deposit-pause copy distinguish market close vs structural break vs skew vs
      stabilization.
- [x] Label indexer/GraphQL failures as indexer errors, not “RPC error”.
- [x] Judge indexer freshness from Ponder `/status`, not the newest swap; an unknown head counts as
      stale, so empty history is never mistaken for healthy.
- [x] Show Urufu Gemu NFT eligibility on the rebate panel before claim (also pre-launch).
- [x] Soften splash/docs copy that implies live pool reads while every pool is pending.
- [x] Separate DeploymentPanel’s WoolFi contracts from existing third-party contracts (Uniswap,
      URU, Urufu Gemu NFT, tokens).

## Optional later (not launch-blocking)

- [ ] Pyth (or other) backup behind `DualOracleAdapter`, with an on-chain failover event.
- [ ] Script that pulls the Chainlink Robinhood directory into `robinhood-batch` config.
- [ ] Frontend oracle-health badges (`oraclePaused`, stale, sequencer down).
- [ ] Show token vs share price using `uiMultiplier()` so dividend/split drift is visible.
- [ ] Surface indexed structural-break, oracle-skew, vault-drawdown, and rebate history in the UI.
- [ ] Site-wide protocol readiness / `launchStatus` banner and an all-18 ops status grid.
- [ ] Tighter swap min-out using the hook’s asymmetric fee model.
- [ ] Auto-compounding LP, concentrated liquidity, limit orders, more pairs, richer analytics.
- [ ] Extend `NyseHoursOracle` for early-close days / holiday maintenance past 2027.
- [ ] Foundry lint cleanup for high/medium warnings in `src`, `script`, and `test`.

## Explicit non-goals

- No Base production deployment.
- No Backed/xStocks, Ondo, Dinari, MSTRX, or cbBTC production integration.
- No STRAND production token or governance rollout.
- No partial catalog launch.
- No fabricated address, fake liquidity, or unverified “live” state.
