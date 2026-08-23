# WoolFi Build TODO

The canonical production design is [`PROJECT_SPEC.md`](./PROJECT_SPEC.md). This file tracks the
remaining work toward the coordinated Robinhood Chain launch; completion boxes do not override
the spec.

## Canonical specification

- [x] Make `PROJECT_SPEC.md` canonical for WoolFi by Urufu Labs on Robinhood Chain 4663.
- [x] Lock the exact 18-pool catalog, including PLTR/WETH.
- [x] Define stock/USDG spot, stock/WETH crypto-beta, stock/stock relative-value, and always-open
      WETH/USDG behavior.
- [x] Replace production STRAND assumptions with externally supplied URU underwriting.
- [x] Record all-18-or-no-launch policy and resumable/non-atomic broadcast semantics.
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
- [x] Configure the indexer for all 18 pools, vaults, and production start blocks.
- [x] Configure, exercise, and monitor the permissionless keeper.
- [ ] Create the production multisig; verify signers, threshold, recovery, and handoff.
- [ ] Publish monitoring, incident-response, and rollback/containment runbooks.
- [ ] Establish the production security-reporting and bug-bounty process.

## Per-pool readiness — exact 18

For every pool below, verify token contracts, oracle adapters, feed proxies, heartbeat/skew limits,
sequencer and market-hours settings, fair-price orientation, risk parameters, URU cap, initial
price, initial liquidity, indexer metadata, and smoke tests.

- [ ] MSTR/USDG
- [ ] COIN/USDG
- [ ] CRCL/USDG
- [ ] NVDA/USDG
- [ ] SPY/USDG
- [ ] GLD/USDG
- [ ] MSTR/WETH
- [ ] COIN/WETH
- [ ] QQQ/WETH
- [ ] NVDA/WETH
- [ ] PLTR/WETH
- [ ] AAPL/MSFT
- [ ] NVDA/SMH
- [ ] SMH/SOXX
- [ ] XLK/QQQ
- [ ] SPY/QQQ
- [ ] GLD/SLV
- [ ] WETH/USDG

## Capital and oracle approvals

- [ ] Approve each per-vault URU cap and aggregate URU treasury cap.
- [ ] Confirm approved URU is available without exceeding either cap.
- [ ] Verify all stock-token pause behavior and all production feed metadata.
- [ ] Verify WETH/USDG feeds and always-open designation.
- [ ] Approve initial liquidity and slippage bounds for all 18 pools.
- [ ] Confirm no placeholder or unverified address is present in production configuration.

## Deployment and launch

- [ ] Complete Robinhood fork tests and no-broadcast simulations.
- [ ] Record explicit approval immediately before every broadcast, retry, or resume.
- [ ] Reconcile receipts and on-chain state after each non-atomic step.
- [ ] Verify bytecode, constructor arguments, ownership, wiring, pool keys, and start blocks.
- [ ] Populate the production manifest only with receipt-backed deployments.
- [ ] Keep all pools pending and user actions disabled during deployment work.
- [ ] Verify frontend, router, indexer, keeper, monitoring, feeds, vaults, and liquidity for all 18.
- [ ] Obtain separate final all-18 coordinated go/no-go approval.
- [ ] Launch none if any pool or shared requirement is incomplete.

## Explicit non-goals

- No Base production deployment.
- No Backed/xStocks, Ondo, Dinari, MSTRX, or cbBTC production integration.
- No STRAND production token or governance rollout.
- No partial catalog launch.
- No fabricated address, fake liquidity, or unverified “live” state.
