# Multisig setup on Robinhood Chain (4663)

Verified on 2026-10-06.

## Is Safe available on 4663?

Yes.

- Safe config service lists chain 4663 ("Robinhood Chain", shortName `robinhood`, L2) with transaction service `https://api.safe.global/tx-service/robinhood`: [safe-config.safe.global/api/v1/chains/4663](https://safe-config.safe.global/api/v1/chains/4663/). This is the same config app.safe.global reads, so the network appears in the Safe web app.
- [safe-deployments](https://github.com/safe-global/safe-deployments) references 4663 (34 code hits, including v1.5.0 assets).
- `eth_getCode` on the RH public RPC confirms bytecode at the canonical addresses:
  - Safe 1.4.1 singleton `0x41675C099F32341bf84BFc5382aF534df5C7461a`
  - SafeL2 1.4.1 `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`
  - SafeProxyFactory 1.4.1 `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`
  - Safe/SafeL2/ProxyFactory 1.3.0 and MultiSendCallOnly 1.4.1 also present

Use SafeL2 (the web app selects it automatically on L2s).

## Create the Safe

1. Open [app.safe.global](https://app.safe.global), connect a signer wallet, and select **Robinhood Chain** in the network picker.
2. **Create account**. Name it `WoolFi Production`.
3. Add signers. Recommended: **2-of-3 minimum**, each signer a hardware wallet held by a different person. 3-of-5 is better once more people are involved.
4. Set the threshold (2 for 2-of-3).
5. Review and deploy. The deploying signer pays gas in ETH on 4663.
6. Record the Safe address, signer list, threshold, and recovery plan in `docs/runbooks/launch-gate-record.md` (Multisig policy approval).
7. Send a small test transaction that requires two signatures before using the Safe for anything real.

Set `MULTISIG=<safe address>` in the deployer's environment. The deploy scripts hard-fail if it is unset or equals the deployer.

## Post-deploy acceptance sequence

Ownership is two-step. After `Deploy.s.sol` broadcasts:

1. **Accept governor ownership (required).** `Deploy.deployWoolFi` only stages it. The Safe must call `WoolFiGovernor.acceptOwnership()`.
2. **Verify position manager owner.** `WoolFiPositionManager` is constructed with the Safe as owner, so no accept is needed. Check `owner()` returns the Safe.
3. **Verify hook governor.** `WoolFiHook.governor()` must equal the `WoolFiGovernor` contract address (the governor accepted the hook role during deploy).

### Safe Transaction Builder payload for step 1

In the Safe app: **Apps > Transaction Builder**, then enter:

- To: `<WoolFiGovernor address>`
- Value: `0`
- Data (custom): `0x79ba5097` (selector for `acceptOwnership()`)

Or as a batch JSON:

```json
{
  "version": "1.0",
  "chainId": "4663",
  "meta": {"name": "WoolFi: accept governor ownership"},
  "transactions": [
    {"to": "<WoolFiGovernor address>", "value": "0", "data": "0x79ba5097"}
  ]
}
```

Collect the threshold signatures and execute.

### Verification commands

```bash
cast call <WoolFiGovernor> "owner()(address)" --rpc-url $ROBINHOOD_RPC_URL          # == Safe
cast call <WoolFiGovernor> "pendingOwner()(address)" --rpc-url $ROBINHOOD_RPC_URL   # == 0x0
cast call <WoolFiPositionManager> "owner()(address)" --rpc-url $ROBINHOOD_RPC_URL   # == Safe
cast call <WoolFiHook> "governor()(address)" --rpc-url $ROBINHOOD_RPC_URL           # == WoolFiGovernor
```

Record each result in the launch gate record before any further privileged step.

## Timelock handoff (before public launch)

Run this after the 18-pool rollout and wiring (deployment doc steps 1 to 9) and before the go/no-go.
Afterwards every owner change waits 3 days in public and the Safe keeps one instant power: the
emergency pause.

What ends up where:

| Contract | Owner after handoff | Why |
|---|---|---|
| `WoolFiGovernor` | timelock (guardian: Safe) | pool config, oracles, vaults, break resolution, unpause |
| `WoolFiPositionManager` | timelock | fee routing (`setFeeConfig`) |
| `UrufuFeeRebateDistributor` | timelock | router binding, caps, `withdrawUnreserved` |
| `WoolFiLiquidityZapper` | timelock | executor allowlist (an allowed executor handles zap inputs) |
| `NyseHoursOracle` / `MultisigMarketHours` | Safe | no funds; holiday or session fixes may be needed the same day |
| Vault `rebalancer` (immutable) | neither the Safe nor the timelock | M-3: seized URU must not return to the governance key |

### 1. Deploy the timelock

```bash
DEPLOYER_PRIVATE_KEY=... MULTISIG=<safe> TIMELOCK_DELAY=259200 CONFIRM_MAINNET=true   forge script script/DeployTimelock.s.sol --rpc-url $ROBINHOOD_RPC_URL --broadcast
```

The script refuses a delay under 3 days (or not above the 2-day unstake cooldown) on 4663, a `MULTISIG` without code, or a `MULTISIG`
equal to the deployer. It records `timelock` in `frontend/lib/deployments/robinhood.json`; copy the
same address into `core.timelock` of the batch config.

Verify (admin must be the timelock itself, never the Safe or the deployer):

```bash
TL=<timelock>
cast call $TL "getMinDelay()(uint256)" --rpc-url $ROBINHOOD_RPC_URL                           # 259200
cast call $TL "hasRole(bytes32,address)(bool)" $(cast keccak PROPOSER_ROLE) <safe> --rpc-url $ROBINHOOD_RPC_URL   # true
cast call $TL "hasRole(bytes32,address)(bool)" $(cast keccak EXECUTOR_ROLE) <safe> --rpc-url $ROBINHOOD_RPC_URL   # true
cast call $TL "hasRole(bytes32,address)(bool)" 0x00 <safe> --rpc-url $ROBINHOOD_RPC_URL                          # false
```

### 2. Generate the two Safe batches

```bash
MULTISIG=<safe> forge script script/TimelockHandoff.s.sol --rpc-url $ROBINHOOD_RPC_URL
```

Read-only (it refuses `--broadcast`). It checks the timelock roles and delay, that each contract is
owned by (or pending to) the Safe, and that no vault rebalancer is the Safe or the timelock, then
writes:

- `script/out/timelock-handoff-1-schedule.json`
- `script/out/timelock-handoff-2-execute.json`

It also prints the timelock operation id. Set `HANDOFF_SALT=<bytes32>` to regenerate with a new id
after a cancel.

### 3. Execute batch 1 (now)

Safe app > **Apps > Transaction Builder** > drag in `timelock-handoff-1-schedule.json`. Check the
decoded calls, in order:

1. `WoolFiGovernor.acceptOwnership()` (only if the deploy-time handoff is still pending)
2. `WoolFiGovernor.setGuardian(<safe>)`
3. `transferOwnership(<timelock>)` on the governor, position manager, rebate distributor and zapper
4. `TimelockController.scheduleBatch(...)` with four `acceptOwnership()` payloads and delay 259200

Collect the threshold signatures and execute. Until batch 2 runs, the Safe still owns everything;
`pendingOwner()` on each contract now returns the timelock.

### 4. Execute batch 2 (3 days later)

Import `timelock-handoff-2-execute.json` (one `executeBatch` call with identical arguments) and
execute it. It reverts if run early.

### 5. Verify

```bash
for c in <governor> <positionManager> <rebateDistributor> <zapper>; do
  cast call $c "owner()(address)" --rpc-url $ROBINHOOD_RPC_URL   # == timelock
done
cast call <governor> "guardian()(address)" --rpc-url $ROBINHOOD_RPC_URL   # == Safe
```

Record the results in the launch gate record.

### Day-to-day after the handoff

- **Any settings change:** in Transaction Builder, call `schedule(target, 0, data, 0x0, salt, 259200)`
  on the timelock with the governor call as `data`; 24 hours later call `execute(target, 0, data,
  0x0, salt)` with the same arguments. Announce the queued change publicly when you schedule it.
- **Emergency:** call `WoolFiGovernor.pauseHook()` directly from the Safe. It takes effect
  immediately. Unpausing is a scheduled `unpauseHook()` through the timelock.
- **Abort a queued change:** `cancel(id)` on the timelock from the Safe, where `id` is
  `hashOperation(target, 0, data, 0x0, salt)`.
- **Changing the delay or roles:** only by scheduling `updateDelay` / `grantRole` / `revokeRole` on
  the timelock itself; there is no admin shortcut.
