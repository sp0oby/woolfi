# WoolFi Build TODO

The canonical production design is [`PROJECT_SPEC.md`](./PROJECT_SPEC.md). This file tracks the
remaining work toward the coordinated Robinhood Chain launch; completion boxes do not override
the spec.

## Canonical specification

- [x] Make `PROJECT_SPEC.md` canonical for WoolFi by Urufu Labs on Robinhood Chain 4663.
- [x] Lock the exact 16-pool catalog (18-pool original; GLD/USDG and GLD/SLV removed after
      Chainlink coverage check on 4663).
- [x] Define stock/USDG spot, stock/WETH crypto-beta, stock/stock relative-value, and always-open
      WETH/USDG behavior.
- [x] Replace production STRAND assumptions with externally supplied URU underwriting.
- [x] Record all-16-or-no-launch policy and resumable/non-atomic broadcast semantics.
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

- [ ] Freeze and audit the hook, position manager, vault, governor, router, adapters, and scripts.
- [x] Wire and verify the position manager on the hook.
- [x] Configure and test the swap router end to end.
- [x] Configure the indexer for all 16 pools, vaults, and production start blocks.
- [x] Configure, exercise, and monitor the permissionless keeper.
- [ ] Create the production multisig; verify signers, threshold, recovery, and handoff.
- [ ] Consider a timelock on governor oracle/config changes after the multisig exists.
- [x] Publish monitoring, incident-response, and rollback/containment runbooks.
- [ ] Establish the production security-reporting and bug-bounty process (paid bounty / Immunefi).
- [ ] Name monitoring owners, alert destinations, and thresholds (runbooks are templates only).
- [ ] Add keeper health/metrics, non-zero exit on failed simulations, and an alert path.
- [ ] Add indexer health/lag alerts; do not rely on frontend 15-minute stale checks alone.

## Oracle and feed verification

Chainlink is the official Robinhood Chain source. Do not invent feed addresses.

- [x] Resolve live Chainlink proxy, decimals, heartbeat, and deviation for every catalog asset
      from the Chainlink Robinhood directory. **All 12 catalog assets covered** after removing
      GLD/USDG and GLD/SLV; inventory in `docs/oracles.md`. All feeds are 8 decimals, 86400s
      heartbeat, 50 bps deviation. Re-verify on-chain before each adapter deploy.
- [x] Resolve the GLD/USD gap — GLD/USDG and GLD/SLV removed from the launch catalog (spec §3).
- [x] Resolve the L2 sequencer uptime feed for chain 4663 — none is published; adapter now
      accepts `sequencerUptimeFeed == address(0) + gracePeriod == 0` as an explicit opt-out, and
      spec §5.1 discloses the operator-trust assumption.
- [ ] Document WETH ↔ ETH/USD alias in the launch record (`0x78F3...` is registered ETH/USD;
      WETH ↔ ETH is 1:1 by contract).
- [ ] Decide the production market-hours source (`NyseHoursOracle` vs `MultisigMarketHours`) and
      bind it for every equity pool.
- [ ] Deploy one `RobinhoodStockOracleAdapter` per stock/ETF leg (with sequencer disabled) and
      one `ChainlinkOracleAdapter` per WETH/USDG leg, pointed at verified proxies.
- [x] Add Robinhood fork tests that read each production feed through those adapters (price
      band, decimals, heartbeat, `oraclePaused()`) — `test/fork/WoolFiPreDeploy.fork.t.sol`
      covers all 10 stock adapters + WETH/USDG + full-stack authorize on real 4663 state; runs
      when `ROBINHOOD_RPC_URL` is set, skips cleanly otherwise.
- [x] Harden `ChainlinkOracleAdapter` with round-completeness (`answeredInRound`) matching the
      stock adapter.
- [x] Decide whether WETH/USDG should also check the sequencer — moot: no sequencer feed on
      4663 for either adapter; both deploy with sequencer disabled and rely on the disclosed
      operator-trust assumption.
- [ ] Decide whether stock/USDG and stock/WETH pools get a positive `maxOracleSkew` (today only
      spread pools require it; default is 0).
- [ ] Record the per-pool launch-record fields in `docs/oracles.md` (feeds, heartbeats, skew,
      hours, expected-value test vectors) — Chainlink inventory landed; per-pool orientation and
      test vectors still to fill.

## Per-pool readiness — exact 16

For every pool below, verify token contracts, oracle adapters, feed proxies, heartbeat/skew limits,
sequencer and market-hours settings, fair-price orientation, risk parameters, URU cap, initial
price, initial liquidity, indexer metadata, and smoke tests.

- [ ] MSTR/USDG
- [ ] COIN/USDG
- [ ] CRCL/USDG
- [ ] NVDA/USDG
- [ ] SPY/USDG
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
- [ ] WETH/USDG

## Capital and oracle approvals

- [ ] Approve each per-vault URU cap and aggregate URU treasury cap.
- [ ] Confirm approved URU is available without exceeding either cap.
- [ ] Verify all stock-token pause behavior and all production feed metadata.
- [ ] Verify WETH/USDG feeds and always-open designation.
- [ ] Approve initial liquidity and slippage bounds for all 16 pools.
- [ ] Confirm no placeholder or unverified address is present in production configuration.

## Deploy automation and CI

- [x] Pass `URU_CAP` from each pool's `vaultAllocationCap` in `robinhood_batch_deploy.py`
      (`CreatePool.s.sol` requires it; batch deploy currently omits it).
- [x] Wire `SeedInitialLiquidity.s.sol` into the batch/orchestrator path with approved amounts.
- [ ] Run `robinhood_batch.py readiness` in CI against a non-example approved config once filled.
- [ ] Wire receipt verify/reconcile into CI; check frontend/indexer/keeper manifest digest parity.
- [ ] Make Robinhood fork tests required when `ROBINHOOD_RPC_URL` is available; keep them honest
      when it is not.
- [ ] Add indexer lockfile, smoke test, and rebate-distributor vars to `indexer/.env.example`.
- [ ] Add `keeper/.env.example` and a keeper/manifest integration check.
- [ ] Add frontend lint and production-env validation (`NEXT_PUBLIC_INDEXER_URL`, WalletConnect).
- [ ] Lock `lib/v4-periphery` in `foundry.lock`.
- [ ] Import indexer ABIs from Foundry `out/` instead of hand-maintained copies.

## Deployment and launch

- [ ] Complete Robinhood fork tests and no-broadcast simulations.
- [ ] Record explicit approval immediately before every broadcast, retry, or resume.
- [ ] Reconcile receipts and on-chain state after each non-atomic step.
- [ ] Verify bytecode, constructor arguments, ownership, wiring, pool keys, and start blocks.
- [ ] Populate the production manifest only with receipt-backed deployments.
- [ ] Keep all pools pending and user actions disabled during deployment work.
- [ ] Verify frontend, router, indexer, keeper, monitoring, feeds, vaults, and liquidity for all 16.
- [ ] Obtain separate final all-16 coordinated go/no-go approval.
- [ ] Launch none if any pool or shared requirement is incomplete.

## Frontend accuracy (before public launch)

- [ ] Make “Recent fees” a true rolling window; it currently sums cumulative routed fees.
- [ ] Make deposit-pause copy distinguish market close vs structural break vs skew vs
      stabilization (it always cites NYSE reopen today).
- [ ] Label indexer/GraphQL failures as indexer errors, not “RPC error”.
- [ ] Treat empty indexer history as stale/unavailable, not healthy.
- [ ] Show Urufu Gemu NFT eligibility on the rebate panel before claim.
- [ ] Soften splash/docs copy that implies live pool reads while every pool is pending.
- [ ] Hide or qualify DeploymentPanel core addresses that are Uniswap infrastructure, not
      WoolFi deployments.

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
