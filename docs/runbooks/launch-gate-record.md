# Launch Gate Record Template

Copy this template into the controlled release record. Empty boxes mean no approval. Repository
configuration must keep `broadcastEnabled`, `launchEnabled`, and every production gate `false`.

## Release identity

- Candidate commit:
- Chain ID (must be 4663):
- Config digest:
- Manifest digest:
- Receipt journal digest:
- Coordinator:
- Planned UTC window:

## Technical evidence

- [ ] Exact 16-pool catalog validated; WETH/USDG is always-open.
- [ ] WETH and USDG use verified plain Chainlink adapters; stock legs use pause-guarded adapters.
- [ ] Core/router/rebate/zapper bytecode, constructor arguments, executor allowlist, wiring, and ownership verified.
- [ ] Every pool key, oracle, market-hours source, risk setting, vault, and fee route verified.
- [ ] 20% (`2000` bps) vault drawdown default and every approved override independently reconciled.
- [ ] Per-pool and aggregate URU caps and balances reconciled.
- [ ] Initial LP amounts, approvals, balances, prices, and slippage simulations recorded.
- [ ] Rebate token caps, funding, liabilities, router binding, and ownership reconciled.
- [ ] Receipt-backed contract and pool start blocks match indexer and keeper.
- [ ] Frontend build/tests, indexer typecheck, keeper tests/typecheck, Python tests, Foundry tests,
      and available Robinhood fork checks passed.
- [ ] Monitoring routes tested; incident and containment owners are available.

## Approval records

Do not prefill names, addresses, decisions, or references.

- Audit approval/reference:
- Multisig policy approval/reference:
- Oracle approval/reference:
- Capital and LP approval/reference:
- Rebate budget approval/reference:
- Operations readiness approval/reference:
- Per-operation broadcast approval/reference:
- Final all-18 go/no-go decision/reference:

## Decision

- [ ] NO-GO (default)
- [ ] GO (requires every item and a separate recorded final approval)

Deployment completion alone does not change this decision.
