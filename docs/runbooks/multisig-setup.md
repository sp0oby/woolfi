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
