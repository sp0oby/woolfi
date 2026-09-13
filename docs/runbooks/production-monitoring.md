# Production Monitoring Runbook

This runbook is configuration, not evidence that WoolFi is live. Alert destinations, owners, and
addresses remain blank until independently approved and receipt-backed.

## Required telemetry

- RPC chain ID, head age, reorg depth, and error/latency rate.
- Indexer head lag and last indexed block for hook, position manager, every vault, and rebate
  distributor.
- Keeper simulation success, broadcast success (when authorized), transaction age, and failed pool.
- Oracle round age, non-positive answers, cross-leg timestamp skew, sequencer status, and
  `oraclePaused()` for each stock token.
- `StructuralBreakTriggered`, cached target, resolution, pool pause state, and vault drawdown.
- LP mint/burn, fee routing, vault assets, per-vault URU cap use, and aggregate URU exposure.
- Rebate funding balance, liability, cap changes, accrual, claims, and available unreserved balance.
- Manifest/config digest, service start blocks, deployed bytecode hash, and frontend/indexer/keeper
  manifest agreement.

## Minimum alert classes

**Page immediately:** wrong chain, invalid/stale oracle, sequencer down, unexpected owner/role,
unknown bytecode, unauthorized pool, corrective-only invariant failure, drawdown above configured
limit, rebate liabilities above balance, or any user-facing service showing a pending pool as live.

**Urgent:** keeper failures across two cadences, indexer lag above the recorded threshold, manifest
drift, failed fee routing, or repeated RPC disagreement.

**Ticket:** capacity warnings, elevated latency, funding runway, and non-critical backfill lag.

Thresholds must be recorded in the launch gate record; this document intentionally supplies no
invented values.

## Deployment checks

1. Export receipt-backed addresses and start blocks from the manifest.
2. Backfill from each contract's own start block. Do not use block zero for a deployed contract.
3. Compare the indexer head with two independent RPC views.
4. Run the keeper with `KEEPER_BROADCAST=false`; require all 16 simulations to succeed.
5. Confirm rebate events are indexed and liabilities reconcile to contract state.
6. Verify every alert route with a non-production test signal and record the evidence.

## Shift checklist

- Confirm all-18 catalog and `launchStatus`.
- Review unresolved structural breaks, paused feeds, stale rounds, and sequencer state.
- Reconcile keeper and indexer failures with transaction receipts.
- Review privileged events and ownership against the approved multisig record.
- Record acknowledged alerts, incident links, and handoff owner.
