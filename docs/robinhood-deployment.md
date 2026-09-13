# Robinhood Production Deployment

**Target:** Robinhood Chain mainnet (`4663`)  
**State:** pre-launch; no WoolFi production deployment exists

This is the operational checklist beneath [`PROJECT_SPEC.md`](../PROJECT_SPEC.md). The public
rollout is all 16 curated pools ready or no launch. The broadcasts themselves are resumable and
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

Stock/USDG: MSTR, COIN, CRCL, NVDA, SPY, AAPL, and TSLA against USDG.

Stock/WETH: MSTR, COIN, QQQ, NVDA, and PLTR against WETH.

Relative-value: AAPL/MSFT, SPY/NVDA, and SPY/QQQ.

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
      verified for the 16 pool configurations.
- [ ] Initial Q64.96 prices, risk settings, slippage bounds, and liquidity for all 16 approved.
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
2. Deploy and verify shared core contracts.
3. Deploy the router/rebate distributor pair, bind the verified Urufu Gemu NFT, and transfer
   distributor ownership to the multisig.
4. Deploy the liquidity zapper, allow only the verified Robinhood Uniswap v3 `SwapRouter02`
   executor, and transfer zapper ownership to the multisig.
5. Wire hook ↔ position manager and transfer all intended ownership to the multisig.
6. Deploy and verify required oracle and market-hours adapters.
7. Create each approved pool and capped URU vault in the canonical catalog.
8. Seed each pool through `SeedInitialLiquidity.s.sol` using approved maxima, minimum shares, and
   deadlines; reset token approvals after each mint.
9. Configure each rebate token with multisig-approved weekly caps and funding. For an EOA-owned
   simulation deployment, `ConfigureRebate.s.sol` performs the same calls; production Safe
   transactions must execute the reviewed calldata directly.
10. Verify receipts, bytecode, constructor arguments, ownership, pool keys, and start blocks.
11. Run read-only smoke checks after every step.
12. Resume from the first incomplete verified step when interrupted.

Do not “repair” an interrupted rollout by inventing addresses or rewriting history. Failed
transactions are not rollbacks of earlier successful transactions. Keep every pool pending until
all 16 and all shared services pass final checks.

## Manifest rules

`frontend/lib/deployments/robinhood.json` is the shared deployment record. Its zero core addresses
and empty pool list correctly mean “not deployed.”

After a successful approved broadcast, record only receipt-backed addresses and start blocks.
The additive writer may update a matching pool in place, but it must reject the wrong chain, zero
required values, or conflicts with already verified shared addresses. Dry runs and tests must not
write production deployment state.

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

It fails closed unless the config contains the exact 16-pool catalog, canonical token addresses,
nonzero approved feeds/adapters/heartbeats, hours policies, safety parameters, treasury caps,
initial prices/liquidity, a receipt-backed 16-pool manifest, RPC code checks on chain 4663, and
every operational gate below set to `true`.

Do not treat the example overlay (`script/config/robinhood-batch.example.json`) as production
input. Zero addresses and `false` gates are the honest pre-approval state.

Dry-run (no broadcast):

```text
python script/robinhood_batch.py deploy --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL
python script/robinhood_batch.py seed --config script/config/robinhood-batch.json --rpc-url $ROBINHOOD_RPC_URL
```

`deploy` forwards each pool's approved `vaultAllocationCap` as `URU_CAP`. `seed` skips
undeployed or already-seeded pools, maps base/quote amounts onto token0/token1 order, and
still requires `CONFIRM_MAINNET=true` before broadcast.

Broadcast remains blocked unless `CONFIRM_MAINNET=true` is set immediately before an approved
run. Interrupted sequences resume from the existing manifest; they are not atomic.

Do not run any of the following until audit approval, complete production inputs, and an
explicit confirmation are all present:

```text
CONFIRM_MAINNET=true forge script script/Deploy.s.sol:Deploy --rpc-url $ROBINHOOD_RPC_URL --broadcast
CONFIRM_MAINNET=true forge script script/DeployRouter.s.sol:DeployRouter --rpc-url $ROBINHOOD_RPC_URL --broadcast
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
- `initialLiquidityApproved`: Q64.96 prices, sizes, and slippage for all 16 approved.
- `keeperReady`: permissionless keeper configured, dry-run exercised, and monitored.
- `indexerReady`: Ponder mappings and start blocks match the intended manifest.
- `frontendReviewed`: dashboard, pending gating, and degraded-state copy reviewed.

## Funding and launch

- Seed no vault above its approved URU cap.
- Seed no pool above its approved liquidity amount.
- Confirm all 16 pools are indexed, readable, correctly gated, and capable of expected dry-run
  user flows.
- Confirm pending/live UI behavior from the final manifest.
- Obtain a separate coordinated go/no-go approval after deployment verification.

Deployment completion does not authorize public launch. If any one pool, feed, vault, service,
audit gate, or safety mechanism is not ready, the launch decision is no-go and all pools remain
pending.

Operational references:

- [`runbooks/production-monitoring.md`](./runbooks/production-monitoring.md)
- [`runbooks/incident-response.md`](./runbooks/incident-response.md)
- [`runbooks/launch-gate-record.md`](./runbooks/launch-gate-record.md)
