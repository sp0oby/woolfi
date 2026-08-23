# STRAND Legacy Reference

**Status:** non-production legacy/testnet documentation

STRAND belongs to WoolFi's earlier Base testnet design. It is not issued, deployed, sold, staked,
or used for governance in the Robinhood production plan.

## Robinhood production position

Robinhood Chain vaults use the existing external **URU** ERC-20 as underwriting capital. The
deployment path receives the staking token as an input and must point it to the independently
verified URU contract. WoolFi does not mint URU and URU underwriting does not grant WoolFi voting
rights.

No STRAND contract, faucet, presale, buyback market, allocation schedule, or STRAND liquidity pool
is part of the 18-pool launch. Production administration is multisig-based.

See [`PROJECT_SPEC.md`](../PROJECT_SPEC.md) for the canonical protocol design and
[`robinhood-deployment.md`](./robinhood-deployment.md) for URU caps and deployment controls.

## Why STRAND remains in the repository

The contracts and historical tests preserve the original underwriting-token implementation and
support non-production regression work. They demonstrate:

- a capped ERC-20 underwriting asset;
- per-pool vault staking and proportional drawdowns;
- fee-reward accounting;
- a possible later votes/permit token design.

Those artifacts are not a production commitment. Documentation, frontend copy, manifests, and
deployment scripts must not expose them as part of Robinhood mainnet.

## Historical Base testnet behavior

Earlier Base Sepolia deployments used mock equity assets and STRAND faucets to exercise vault,
fee-routing, and governance flows. Any addresses associated with those deployments are testnet
only and must not be reused as Robinhood production inputs.

Historical tokenomics, sale, vesting, and STRAND-governance sketches are retired production
assumptions. Recover them from repository history if needed for research; do not treat them as the
current WoolFi specification.
