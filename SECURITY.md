# Security Policy

WoolFi is pre-launch, unaudited DeFi infrastructure handling real value. The way you report a problem matters as much as the problem itself.

## Reporting a vulnerability

**Do not open a public GitHub issue for a security vulnerability.**

Instead, use GitHub's private vulnerability reporting:

1. Go to <https://github.com/sp0oby/woolfi/security/advisories/new>
2. Describe the issue with enough detail that we can reproduce it. A proof-of-concept transaction, foundry test, or trace is ideal.
3. Include a contact you check regularly so we can coordinate timing.

We will acknowledge receipt within 72 hours and aim to triage within 7 days. If we believe the report describes a real vulnerability we will work with you on a fix, a disclosure timeline, and credit.

If GitHub's private-advisory flow is unavailable for any reason, open a minimal public issue saying only "I have a security report - please share a private channel," and we will respond there with a private channel.

## Scope

In scope for security reporting:

- Any production-path contract under [`src/`](./src) - the hook, position manager, vault, governor,
  oracle adapters, and swap router. Legacy STRAND contracts remain reviewable but are not part of
  the Robinhood production deployment.
- Deployment scripts under [`script/`](./script) when they affect deployed-contract state.
- Front-end code under [`frontend/`](./frontend) that could lead to a user signing a transaction that does something other than what they intended (e.g. wrong calldata, wrong recipient, malicious approval).

Out of scope:

- The mocked tokens, mock oracles, and mock market-hours contracts under [`src/mocks/`](./src/mocks) - these exist for the testnet build and are explicitly not production.
- Issues in the underlying Uniswap v4 PoolManager, OpenZeppelin contracts, Solady, or other vendored dependencies - report those to their respective maintainers.
- Issues that require trusted-party privileges to exploit (e.g. "the governor can authorize a malicious pool"). The governor IS trusted; the question is whether non-privileged callers can do harm.
- Front-end issues that do not affect transaction integrity (typos, layout bugs, broken non-action links).

## Bug bounty

There is no paid bounty program before mainnet launch. We will set one up on Immunefi (or similar) at or before mainnet and back-credit serious testnet findings where appropriate. Good-faith reporters during the pre-mainnet window will be acknowledged in the release notes and offered a place on the post-mainnet disclosure list.

## What you can assume about deployed code

- The `main` branch is the active build target. Tagged releases will start once we are past the first external audit.
- Historical Base Sepolia broadcasts use mocked/test assets and are non-production regression
  artifacts. They are not appropriate places to entrust value.
- No WoolFi protocol contract or pool is deployed on Robinhood Chain as of the current spec.

## What we ask of you

- Test locally or with explicitly labeled test/fork infrastructure, not against Robinhood WoolFi
  contracts that do not exist.
- Do not run automated scanners against the live RPC nodes - please clone and run locally with Foundry's fork mode.
- Give us a reasonable disclosure window before publishing. We will not slow-walk fixes; we will not stand in the way of disclosure once a fix is live.

Thank you for helping make this safer.
