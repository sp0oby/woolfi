# Robinhood Production Deployment

**Target:** Robinhood Chain mainnet (`4663`)  
**State:** pre-launch; no WoolFi production deployment exists

This is the operational checklist beneath [`PROJECT_SPEC.md`](../PROJECT_SPEC.md). The public
rollout is all 18 curated pools ready or no launch. The broadcasts themselves are resumable and
non-atomic.

## Known chain inputs

- Uniswap v4 PoolManager: `0x8366a39cc670b4001a1121b8f6a443a643e40951`
- External URU staking token: `0x9fbe210007dDd8389f98d0253018e65CC48b9D24`
- Urufu Gemu NFT: `0x60cb7082c8c14b4237c6a24c65e7c2e7abe2bd17`
- WETH: `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- USDG: `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`

These are configuration inputs, not WoolFi deployment addresses. Verify chain ID, code, symbols,
decimals, ownership/proxy state, and current official sources immediately before use.
Stock assets use `RobinhoodStockOracleAdapter`; WETH and USDG use the plain
`ChainlinkOracleAdapter` deployment path and must not be subjected to stock-token pause calls.

## Required launch set

Stock/USDG: MSTR, COIN, CRCL, NVDA, SPY, GLD, AAPL, and TSLA against USDG.

Stock/WETH: MSTR, COIN, QQQ, NVDA, and PLTR against WETH.

Relative-value: AAPL/MSFT, SPY/NVDA, SPY/QQQ, and GLD/SLV.

Always open: WETH/USDG.

No additional pool and no substitute pair may be included without first updating the canonical
spec. A subset may be deployed during an interrupted sequence, but no subset may be publicly
launched or marked live.

## Pre-broadcast gates

- [ ] External audit complete; critical/high findings resolved.
- [ ] Cached-break corrective-only mode, post-open stabilization, dual-leg timestamp-skew checks,
      and closed-path sequencer safety audited (implemented and covered in-repo).
- [ ] Production multisig address, signer threshold, recovery, and transaction policy approved.
- [ ] Position manager, router, indexer, keeper, monitoring, and incident runbook ready.
- [ ] Urufu Gemu NFT contract verified on Robinhood Chain.
- [ ] Rebate distributor bound to the verified hook/router; token budgets and weekly caps approved.
- [ ] External URU configured; no STRAND deployment in the production path.
- [ ] Per-vault URU caps and aggregate URU treasury cap explicitly approved.
- [ ] All stock token, WETH, and USDG contracts verified.
- [ ] All price feeds, heartbeats, sequencer settings, market-hours settings, and oracle adapters
      verified for the 18 pool configurations.
- [ ] Initial Q64.96 prices and risk settings for all 18 approved; slippage bounds and liquidity
      approved for the seed set (`seedSet`, currently `weth-usdg` and `nvda-usdg`).
- [ ] Fork tests, formatting, build, tests, and dry-run scripts pass.
- [ ] Frontend and indexer configuration reviewed against the intended manifest.
- [ ] No zero, placeholder, or fabricated production address is presented as deployed.

## Broadcast approval policy

Every command that submits transactions needs explicit multisig approval immediately before it is
run. Approval for a dry run is not broadcast approval. Approval for an earlier transaction is not
approval for a retry, resume, changed nonce, changed calldata, or later pool.

Record the command, chain ID, signer, nonce range, calldata/configuration digest, simulation output,
and approval reference. Re-check them before every broadcast.

## Resumable, non-atomic sequence

1. Reconcile on-chain state and the local manifest; never assume a previous transaction landed.
2. Deploy and verify shared core contracts with `MULTISIG` set to the production multisig.
   `Deploy.s.sol` hard-fails if `MULTISIG` is unset or equals the deployer on chain 4663. It
   mines and deploys the hook, proposes and accepts the hook `governor` role for
   `WoolFiGovernor`, wires hook ↔ position manager, and *starts* the two-step handoff of
   `WoolFiGovernor` ownership to `MULTISIG` (`Ownable2Step`: the script only proposes).
3. From the multisig, call `acceptOwnership()` on `WoolFiGovernor`. Until that call lands the
   deployer key still owns governance and no pool may be authorized. Verify `owner()` equals
   the multisig and `pendingOwner()` is zero on the governor, and that
   `WoolFiPositionManager.owner()` is the multisig, before continuing.
4. Deploy the router/rebate distributor pair, bind the verified Urufu Gemu NFT, and transfer
   distributor ownership to the multisig.
5. Deploy the liquidity zapper, allow only the verified Robinhood Uniswap v3 `SwapRouter02`
   executor, and transfer zapper ownership to the multisig.
6. Deploy one oracle adapter per catalog asset with `script/deploy_oracle_adapters.py`
   (`RobinhoodStockOracleAdapter` for stocks and ETFs, `ChainlinkOracleAdapter` for WETH and
   USDG). It reads `assets.<SYMBOL>.{token,feed,heartbeat,oracleKind}` from the batch config,
   skips any asset whose `oracle` is already recorded, and on broadcast writes each new adapter
   address back into `assets.<SYMBOL>.oracle` so an interrupted run resumes cleanly. With
   `core.sequencerUptimeFeed` zero (spec §5.1) stock adapters deploy with the sequencer guard
   disabled. Verify each adapter's `getPrice()` on a fork, then bind the market-hours source in
   `core.marketHours`.
7. Create each approved pool and capped URU vault in the canonical catalog. All 18 pools are
   created and initialized at their computed launch price.
8. Seed only the `seedSet` pools through `SeedInitialLiquidity.s.sol` using approved maxima,
   minimum shares, and deadlines; reset token approvals after each mint. Pools outside the seed
   set stay at zero liquidity, open to community LPs and v3 migration (spec section 9.1). On
   broadcast `robinhood_batch.py seed` records every seeded slug in `manifest.seededPools` and sets
   `seeded: true` on that manifest pool entry, so a resumed run never double-seeds and the
   frontend can show which live pools still need a first LP.
9. Configure each rebate token with multisig-approved weekly caps and funding. For an EOA-owned
   simulation deployment, `ConfigureRebate.s.sol` performs the same calls; production Safe
   transactions must execute the reviewed calldata directly.
10. Verify receipts, bytecode, constructor arguments, ownership, pool keys, and start blocks.
11. Run read-only smoke checks after every step.
12. Resume from the first incomplete verified step when interrupted.

Do not “repair” an interrupted rollout by inventing addresses or rewriting history. Failed
transactions are not rollbacks of earlier successful transactions. Keep every pool pending until
all 18 and all shared services pass final checks.

## Manifest rules

`frontend/lib/deployments/robinhood.json` is the shared deployment record. Its zero core addresses
and empty pool list correctly mean “not deployed.”

After a successful approved broadcast, record only receipt-backed addresses and start blocks.
The additive writer may update a matching pool in place, but it must reject the wrong chain, zero
required values, or conflicts with already verified shared addresses. Dry runs and tests must not
write production deployment state.

`launchStatus` is the single public-launch switch read by the frontend, indexer, and keeper. No
script writes it; it stays `"pending"` through the entire deployment and is flipped by hand only
at the go/no-go step described under "Funding and launch".

For every pool, record its vault mapping and start block in the indexer. Verify that the router,
position manager, hook, governor, vault, and oracle references all resolve to the same deployment.
Record the verified Urufu Gemu NFT, rebate distributor, liquidity zapper, and external swap
executor once at the deployment root. The production frontend enables one-token deposits only when
the receipt-backed zapper and executor fields are present.

## Readiness command

The machine-readable gate is:

```text
python script/robinhood_batch.py readiness --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL
```

Validate and print the immutable no-broadcast operation plan:

```text
python script/launch_orchestrator.py validate
python script/launch_orchestrator.py plan
```

`run-dry` executes only operations with commands, forces `CONFIRM_MAINNET=false`, records
successful simulation digests under `.launch-state/`, and stops at evidence checkpoints. Re-running
it skips only an operation whose exact digest already passed.

After an approved broadcast performed under the policy above, copy the empty receipt template,
record actual transaction hashes/blocks/contracts, and verify it against RPC before updating the
manifest:

```text
python script/launch_orchestrator.py verify-receipts --receipts <journal.json> --rpc-url <rpc>
python script/launch_orchestrator.py reconcile --receipts <journal.json> --rpc-url <rpc>
```

Reconciliation rejects failed/missing receipts, block mismatches, addresses without code at the
receipt block, unsupported fields, and conflicts with existing manifest values.

It fails closed unless the config contains the exact 18-pool catalog, canonical token addresses,
nonzero approved feeds/adapters/heartbeats, hours policies, safety parameters, treasury caps,
initial prices/liquidity, a receipt-backed 18-pool manifest, RPC code checks on chain 4663, and
every operational gate below set to `true`. `core.sequencerUptimeFeed` is the one address that
may be zero (spec §5.1 sequencer opt-out); when it is zero, `core.sequencerGracePeriod` must
also be zero, and when it is set it must have code and a positive grace period.

Do not treat the example overlay (`script/config/robinhood-batch.example.json`) as production
input. Zero addresses and `false` gates are the honest pre-approval state. The real
`script/config/robinhood-batch.json` and `launch-operations.json` are gitignored on purpose.

Dry-run (no broadcast):

```text
python script/deploy_oracle_adapters.py --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL
python script/robinhood_batch.py deploy --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL
python script/robinhood_batch.py seed --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL
```

`deploy_oracle_adapters.py` deploys one adapter per asset whose `oracle` is still zero and, on
broadcast, writes the address back into the config. `deploy` forwards each pool's approved
`vaultAllocationCap` as `URU_CAP`. `seed` skips pools outside `seedSet` and undeployed or
already-seeded pools, maps
base/quote amounts onto token0/token1 order, records seeded slugs in `manifest.seededPools` on
broadcast, and still requires `CONFIRM_MAINNET=true` before broadcast.

Broadcast remains blocked unless `CONFIRM_MAINNET=true` is set immediately before an approved
run. Interrupted sequences resume from the existing manifest; they are not atomic.

Do not run any of the following until audit approval, complete production inputs, and an
explicit confirmation are all present. `Deploy.s.sol`, `DeployRouter.s.sol`, and
`DeployLiquidityZapper.s.sol` additionally require `MULTISIG` in the environment and refuse to
run if it equals the deployer:

```text
CONFIRM_MAINNET=true MULTISIG=<safe> forge script script/Deploy.s.sol:Deploy --rpc-url $ROBINHOOD_RPC_URL --broadcast
CONFIRM_MAINNET=true MULTISIG=<safe> forge script script/DeployRouter.s.sol:DeployRouter --rpc-url $ROBINHOOD_RPC_URL --broadcast
CONFIRM_MAINNET=true python script/deploy_oracle_adapters.py --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL --broadcast
CONFIRM_MAINNET=true python script/robinhood_batch.py deploy --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL --broadcast
```

Read-only verification that is safe to run now:

```text
forge test --match-path test/fork/RobinhoodMainnet.fork.t.sol
python script/robinhood_batch.py readiness --config script/config/robinhood-batch.example.json --rpc-url $ROBINHOOD_RPC_URL
```

## Operational gates encoded in the batch config

- `auditComplete`: external audit finished; critical/high findings resolved.
- `multisigApproved`: production signer set, threshold, recovery, and policy recorded.
- `uruCapsApproved`: per-vault and aggregate URU caps approved.
- `oraclesVerified`: feeds, heartbeats, adapters, sequencer, and hours sources verified.
- `initialLiquidityApproved`: Q64.96 prices for all 18, and seed sizes and slippage for the
  seed set, approved.
- `keeperReady`: permissionless keeper configured, dry-run exercised, and monitored.
- `indexerReady`: Ponder mappings and start blocks match the intended manifest.
- `frontendReviewed`: dashboard, pending gating, and degraded-state copy reviewed.

## Funding and launch

1. Seed no vault above its approved URU cap.
2. Seed no pool above its approved liquidity amount, and seed no pool outside `seedSet`.
   Do not fund treasury URU into an unseeded pool's vault until that pool has liquidity
   (phantom-break drawdown risk, spec section 9.1).
3. Confirm all 18 pools are indexed, readable, correctly gated, and capable of expected dry-run
   user flows.
4. Confirm pending/live UI behavior from the final manifest.
5. Obtain a separate coordinated go/no-go approval after deployment verification.
6. Only after that approval, flip the launch switch. Nothing in the tooling writes it. Hand-edit
   `frontend/lib/deployments/robinhood.json` and change `"launchStatus": "pending"` to
   `"launchStatus": "live"`, commit it with the approval reference, then redeploy the indexer,
   the keeper, and the frontend. All three gate on this field: until they read `"live"` the
   frontend shows every pool as pending, the indexer indexes nothing, and the keeper exits with
   `{ready:false}`. Verify each of the three reports live before announcing.

Deployment completion does not authorize public launch. If any one pool, feed, vault, service,
audit gate, or safety mechanism is not ready, the launch decision is no-go and all pools remain
pending.

Operational references:

- [`runbooks/production-monitoring.md`](./runbooks/production-monitoring.md)
- [`runbooks/incident-response.md`](./runbooks/incident-response.md)
- [`runbooks/launch-gate-record.md`](./runbooks/launch-gate-record.md)

## Arbitrage executor (optional, permissionless)

`src/periphery/WoolFiArbExecutor.sol` is the zero-capital executor used by `arb-agent/`. It has
no owner, holds no funds between transactions, and is not part of the coordinated launch gate:
anyone may deploy their own instance. It is not wired into the hook, position manager, or
manifest.

```text
POOL_MANAGER=0x8366a39cc670b4001a1121b8f6a443a643e40951 \
SWAP_EXECUTOR=0xCaf681a66D020601342297493863E78C959E5cb2 \
forge script script/DeployArbExecutor.s.sol:DeployArbExecutor --rpc-url $ROBINHOOD_RPC_URL
```

Broadcasting on 4663 additionally needs `--broadcast` and `CONFIRM_MAINNET=true`. Run the
agent against the live manifest only after `launchStatus` is `live`; until then it reports
`ready: false` and does nothing. At least one agent per launch should be running from day one:
pools with no active arbitrage stay off fair longer, which is the condition the structural-break
confirmation window is designed around.

## Uniswap v3 position migrator (optional)

`WoolFiV3Migrator` lets an existing Uniswap v3 LP move a position for a catalog pair into the
matching full-range WoolFi pool in one transaction: withdraw from v3, collect principal plus
uncollected v3 fees, mint WoolFi LP shares, refund whatever the full-range ratio cannot use. The
v3 NFT stays with its owner, emptied.

- Uniswap v3 NonfungiblePositionManager on 4663: `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`
  (Uniswap sdk-core address book; `factory()` = `0x1f7d...2efa`, `WETH9()` = canonical WETH, both
  verified on-chain 2026-10-07).
- The migrator is stateless and permissionless: no owner, no admin, holds no funds between
  transactions. There is no ownership handoff step.
- Out-of-range v3 positions hold one token and revert with `SingleSidedPosition`; those users
  should withdraw on Uniswap and use the Zap.
- Deploy after the WoolFi position manager exists. The script checks the NPM's factory and WETH9
  on 4663 and, on broadcast, writes `v3Migrator` and `uniswapV3PositionManager` to the manifest.
  The terminal shows the "Migrate v3" liquidity mode only when `v3Migrator` is set.

Dry-run:

```text
POSITION_MANAGER=<woolfi pm> forge script script/DeployV3Migrator.s.sol:DeployV3Migrator --rpc-url $ROBINHOOD_RPC_URL
```

Broadcast (approved run only):

```text
CONFIRM_MAINNET=true POSITION_MANAGER=<woolfi pm> forge script script/DeployV3Migrator.s.sol:DeployV3Migrator --rpc-url $ROBINHOOD_RPC_URL --broadcast
```
