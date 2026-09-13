# Incident Response and Containment

There is no automatic deployment rollback. Confirmed transactions and initialized pools remain
on-chain. "Rollback" means containing risk, stopping publication and automation, and restoring a
previously verified service/configuration version where technically possible.

## First response

1. Open an incident record; capture UTC time, reporter, chain head, affected pools, transaction
   hashes, and current config/manifest digest.
2. Stop new deployment submissions. Disable keeper broadcasting while preserving read-only
   simulations.
3. Set frontend/service launch gates to pending through the approved release process. Never edit
   receipts or replace addresses to hide a deployment.
4. Preserve logs, RPC responses, simulation results, and multisig transaction data.
5. Classify: oracle/sequencer, pool safety, vault/URU, rebate, privileged access, indexer/keeper,
   frontend publication, or interrupted deployment.

## Containment by class

- **Oracle/sequencer:** use the governed pause/break controls only after simulation and required
  multisig approval. Keep withdrawals available. Do not substitute a feed ad hoc.
- **Pool drift/break:** preserve cached fair value, allow only contract-enforced corrective flow,
  and verify drawdown remains within both configured drawdown and approved URU cap.
- **Vault/capital:** stop further funding and LP seeding; reconcile balances, shares, fee assets,
  and aggregate exposure.
- **Rebates:** set affected weekly cap to zero through approved governance if necessary; do not
  remove assets reserved by `totalLiability`.
- **Indexer/keeper:** stop writes/broadcasts, retain read-only checks, repair from receipt-backed
  start blocks, and compare against on-chain state before resuming.
- **Publication:** mark every pool pending. A partial healthy subset is not a launch option.
- **Interrupted deployment:** reconcile each submitted transaction by receipt and bytecode. Resume
  only from the first incomplete operation with a new explicit approval.

## Recovery gates

- Root cause and affected interval documented.
- On-chain state, ownership, code, pool keys, oracle settings, caps, balances, and manifest
  reconciled independently.
- Fork/read-only simulation and relevant CI checks pass.
- Monitoring catches the original failure mode.
- Required security and operational reviewers record recovery approval.
- A separate all-18 go/no-go decision is recorded before publication resumes.

## Evidence template

- Incident ID:
- Severity:
- UTC opened/resolved:
- Coordinator:
- Affected contracts/pools:
- Transaction hashes and blocks:
- Manifest/config digest:
- Containment actions and approval references:
- User impact:
- Root cause:
- Recovery verification:
- Follow-up owners and due dates:
