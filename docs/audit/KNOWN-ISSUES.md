# Known Issues

## Fixed before audit

| Issue | Fix |
|---|---|
| One-step ownership could strand governance | `WoolFiGovernor` is `Ownable2Step`; PM has `transferOwnership` + `acceptOwnership`; hook has `proposeGovernor` + `acceptGovernor` |
| A reverting vault rolled back the break flag and bricked the pool | `vault.drawdown` wrapped in try/catch, `DrawdownFailed` event, break persists |
| Base fee above the asymmetric cap inverted the mechanic | `MAX_BASE_FEE_BPS` lowered to 100, matching `SpreadMath.MAX_FEE_CAP_BPS` |
| 100% drawdown bricked future staking | `setVault` rejects `drawdownBps >= 10_000` |
| One large swap could break a thin pool | Single-swap break guard (`SwapWouldBreakPool`) |
| `realizeFromHook` lacked a reentrancy guard | Now `nonReentrant` |
| H-1 guard bypass in flat-fee modes | Guard runs on every non-break path; closed/stabilizing measure against `getLastValidPrice()` |
| M-1 parking drift just under the threshold | Two-phase breaks: flag now, `confirmStructuralBreak` after a window draws down once or clears |
| M-2 rebate on base fee for discounted swaps | Rebate uses `min(fee charged, base fee)` via the hook's transient `lastSwapFeeBps` |
| L-1 one-step ownership on secondary contracts | Zapper, rebate distributor, `NyseHoursOracle`, `MultisigMarketHours` are two-step |
| L-4 locked rebate funds | `withdrawUnreserved` moves only funds above outstanding liabilities |
| R2-1 spread pools always skewed | Spread `maxOracleSkew` sized to the 24h feed heartbeat (86400); readiness gate enforces it |
| R2-2 confirmation raced at the open | Confirm refused during stabilization; equity-hours window counts from the later of detection and session open |
| R2-3 indexer missed break transitions | Break-episode tracking for detected / confirmed / cleared / recovered / resolved and drawdown outcome |
| R2-4 confirmed break never self-exits | Permissionless `clearRecoveredBreak` once fresh drift is back within tolerance |
| R2-6 rebate on requested input | Router passes the settled input amount |

## Operational requirements from fixes

- **Off-chain keeper must learn the new paths.** `keeper/src/keep.ts` treats only
  `NotStructurallyBroken|BreakConfirmationPending|BreakAlreadyConfirmed` as idle. It should also
  treat `MarketClosed`, `StabilizationActive` and `OracleTimestampSkew` as idle, and call
  `clearRecoveredBreak` for confirmed breaks (or route through `RebalanceKeeper.keep`, which does both).
- **Thin-pool residual (R2-5).** Two-phase breaks assume corrective flow arrives within the window.
  A pool with no active arbitrageur can still confirm and draw down on a genuine gap. Run an
  arbitrage keeper per pool.

- **Keeper must confirm breaks.** Detection no longer draws down. `keeper/src` must call
  `hook.confirmStructuralBreak(key)` (or route through `RebalanceKeeper.keep`, which now does it)
  once `hook.breakStatus(key)` reports `broken && !confirmed && now >= confirmReadyAt`. Without
  this, a real break stays contained but underwriters are never drawn down. `confirmStructuralBreak`
  is permissionless, so anyone can also call it. `RebalanceKeeper.keep` swallows a confirmation
  that cannot run yet (market closed, skew, pause) and emits `BreakConfirmAttempted`.
- **Break confirmation window.** Default 1 hour. Set per pool via
  `WoolFiGovernor.setBreakConfirmSeconds(key, seconds)` (max 1 day; zero restores the default). It is
  a separate governor call rather than a `SafetyParams` field so the `AuthParamsV2` ABI used by
  `CreatePool.s.sol`, the fork tests and the frontend stays unchanged.
- **New oracle method.** Every `IPriceOracle` implementation must provide `getLastValidPrice()`.
  All in-repo adapters do.
- **Two-step acceptance after deploy.** The multisig must call `acceptOwnership()` on the
  governor, the rebate distributor and the liquidity zapper (and on any market-hours oracle whose
  ownership is transferred).

## Accepted and documented

- M-2 residual: weekly rebate caps are per wallet. The Urufu Gemu NFT is not ERC721Enumerable
  (`supportsInterface(0x780e9d63)` returns false on 4663), so caps cannot be keyed by token id. One
  NFT moved between wallets still earns a fresh cap per wallet, now bounded by realized-fee rebates
  and by funding.
- M-3 governance drain (trust risk). Mitigations before launch:
  - The vault `rebalancer` must not be the multisig. Use a dedicated rebalance executor contract
    or a second Safe with a different signer set, so seized URU cannot flow straight back to the
    governance key.
  - Put an OpenZeppelin `TimelockController` (minimum delay 24 hours or more) in front of the
    governor owner for oracle rebinding (`updatePoolConfig*`), vault wiring (`setVault`), break
    resolution and confirmation-window changes. Deploy note: deploy `TimelockController(minDelay,
    proposers=[Safe], executors=[Safe], admin=address(0))`, then have the governor owner call
    `transferOwnership(timelock)` and schedule plus execute `acceptOwnership()` through the timelock.
    Keep `pauseHook` reachable without delay, either by leaving pause on a separate guardian path
    in a future governor revision or by accepting the delay. No timelock deploy script is in this repo.
  - The confirmation window adds a public delay before every drawdown, giving stakers and monitors
    time to see a suspicious break.
- L-2 reverting sinks and unchecked `setFeeConfig` vault: owner-configured, verified in the launch
  gate record.
- L-3 market-hours owner controls fee mode: trust assumption; the owner is now two-step and the
  guard covers closed-market trading.
- Stabilization only applies when a session open falls inside the window; resolving a break does
  not start a cooldown (spec 6, item 6).
- No sequencer uptime guard on 4663; adapters deploy with the guard disabled (spec 5.1).
- The guard and the rebate fee use EIP-1153 transient storage. Robinhood Chain must run ArbOS 20 or
  later; fork tests pass against 4663, but confirm the ArbOS version before deploy.
- LP shares are non-transferable (ERC-6909 transfers revert).
- GLD/USD feed on 4663 is named "GLD / USD", not "Robinhood GLD / USD", and may not use Total
  Return Value semantics like the stock feeds.
