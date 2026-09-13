# WoolFi — indexer

[Ponder](https://ponder.sh) indexer for the WoolFi protocol. Watches one shared hook and position
manager plus every configured pool vault; exposes a GraphQL + SQL API the dashboard reads from.

## What it tracks

| Table              | Source                              | Used by                                      |
| ------------------ | ----------------------------------- | -------------------------------------------- |
| `swap`             | `WoolFiHook.SwapProcessed`           | Recent swaps, drift series, 24h fee proxy    |
| `structural_break` | `WoolFiHook.StructuralBreak*`        | Break history, current pool state            |
| `lp_movement`      | `WoolFiPositionManager.Mint`/`Burn`  | Per-LP positions, TVL changes                |
| `fee_routing`      | `WoolFiPositionManager.FeesRouted`   | Vault accrual + treasury policy over time    |
| `vault_event`      | `WoolFiUnderwritingVault.*`          | Stakes, unstakes, drawdowns                  |
| `oracle_skew`      | `WoolFiHook.OracleSkewObserved`      | Degraded-mode history                        |
| `pool_safety`      | `WoolFiHook.PoolSafetyUpdated`       | Stabilization / skew config changes          |
| `rebate_event`     | `UrufuFeeRebateDistributor.*`        | Caps, funding, accruals, and claims          |

This is a deliberately minimal starter set — extend `abis/`, `ponder.schema.ts`, and `src/index.ts`
as the dashboard grows (e.g., LP fee claims, governance events, market-hours transitions).

## Run

```bash
cp .env.example .env.local
# fill in the selected RPC URL, receipt-backed addresses/start blocks, and PONDER_VAULTS
npm install
npm run dev    # starts ponder dev — http://localhost:42069
```

Configure vaults as a comma-separated `vault=poolId` list:

```dotenv
PONDER_VAULTS=0x1111111111111111111111111111111111111111=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,0x2222222222222222222222222222222222222222=0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

Each vault and pool ID must be unique. Entries are validated when Ponder loads its config. If the
variable is empty, a zero-address placeholder keeps predeployment code generation available.
Set `PONDER_REBATE_ADDRESS` and `PONDER_REBATE_START_BLOCK` from the same verified manifest and
receipt journal. A deployed contract must never backfill from block zero.

## Notes

- Event IDs are `${tx.hash}-${log.logIndex}` so re-orgs are idempotent.
- Every `vault_event` stores both the emitting vault and its configured pool ID.
- PM events emit `id` as `uint256` (the share id == `uint256(PoolId.unwrap(poolId))`); handlers
  cast it back to a 32-byte hex string for consistency with the hook's `bytes32 PoolId`.
- ABIs in `abis/index.ts` cover only the events handlers consume. When deploying for real, switch
  to importing from `../out/*/X.json` so they stay in lockstep with the contracts automatically.
