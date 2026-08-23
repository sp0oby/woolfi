# Contributing to WoolFi by Urufu Labs

Thank you for considering a contribution. WoolFi is a small, opinionated codebase - clarity beats cleverness, tests are non-negotiable, and the spec is the source of truth. This document tells you how to land a change cleanly.

For a high-level project overview start with [README.md](./README.md). The full reference is [PROJECT_SPEC.md](./PROJECT_SPEC.md); the build plan is [TODO.md](./TODO.md).

## What we accept

- Bug fixes with regression tests.
- Documentation improvements (clarity, accuracy, missing context).
- Test additions - especially boundary cases and additional fuzz/invariant properties.
- Frontend polish and accessibility fixes.
- Oracle adapter implementations against `IPriceOracle` or `IMarketHoursOracle`.

If you are considering a larger change - new mechanic, new mechanism, breaking API change - please [open a Discussion](https://github.com/sp0oby/woolfi/discussions) first. We will tell you whether the change fits the spec, whether the spec needs to change first, and what the test bar will be.

## Reporting bugs

For non-security bugs, [open an issue](https://github.com/sp0oby/woolfi/issues/new) with:

- A short title.
- The expected vs actual behavior.
- A minimal reproduction - a failing Foundry test is the gold standard; for deployment-path issues,
  include a clearly identified testnet, fork, or Robinhood transaction hash.
- The environment (Foundry version, Node version if frontend, browser if a UI bug).

For **security bugs**, follow [SECURITY.md](./SECURITY.md) instead. Do not open public issues for security reports.

## Development setup

Prerequisites: [Foundry](https://book.getfoundry.sh/), Node 20+.

```bash
git clone https://github.com/sp0oby/woolfi.git
cd woolfi
git submodule update --init --recursive
forge build
forge test
```

Frontend:

```bash
cd frontend
npm install
npm run dev          # http://localhost:3000
```

Indexer (Ponder):

```bash
cd indexer
npm install
cp .env.example .env.local       # fill in addresses + RPC
npm run dev
```

## Coding standards

### Solidity

- Pinned to `0.8.26` to match Uniswap v4.
- **`forge fmt --check` must pass.** Run `forge fmt` before committing - it is enforced in CI.
- Function order: `constructor`, external/public state-changing, external/public view/pure, internal, private.
- NatSpec on every external/public function (`@notice`, `@param`, `@return` at minimum, `@dev` where helpful).
- Custom errors, not `require` strings.
- No magic numbers - declare as `constant` or `immutable` with a comment explaining the value.
- No `unchecked` blocks without a comment proving overflow is impossible.
- Events for every state change that an indexer would care about.

### TypeScript / frontend

- Strict TypeScript, no `any` outside ABI / contract-result boundaries.
- Tailwind for styling; the design language is editorial dark - no shadcn, no animation libraries.
- Server components by default; client components when state or wallet hooks are needed.

### Commits and PRs

- Branch from `main`. Keep PRs focused - one logical change per PR.
- Commit messages: short imperative subject (≤ 70 chars), longer body explaining the *why*.
- Reference issue numbers in the body, not the subject.
- **Do not add Claude, Cursor, or any AI tool as a co-author or contributor.** This is a solo-maintained project.
- Rebase on `main` before requesting review; do not merge `main` into your branch.

## Tests

Every contribution that touches a contract needs tests in the same PR. Coverage targets (from [CLAUDE.md](./CLAUDE.md)-equivalent standing instructions - kept locally, paraphrased here):

- Math libraries: 100% line, 100% branch, 50k+ fuzz runs.
- Hook callbacks: 100% line, all revert paths covered.
- Vault / governance: 95% line, all access controls covered.

Test naming convention:

- `test_<function>_<scenario>` - happy paths
- `testRevert_<function>_<reason>` - explicit revert assertions (use `vm.expectRevert(SpecificError.selector)`, not blanket `vm.expectRevert()`)
- `testFuzz_<function>_<property>` - fuzz properties
- `invariant_<property>` - Foundry invariants

Boundary conditions are explicit tests, not "we'll catch it in fuzz." Off-by-one is a real and recurring source of DeFi bugs.

## What we will not merge

- A PR that disables a failing test to make CI green. Either fix the underlying issue or document explicitly why the test is skipped.
- A PR that adds a new external dependency without prior discussion. The approved list is in [foundry.toml](./foundry.toml); additions are a decision, not a default.
- A PR that bypasses pre-commit hooks (`--no-verify`) or commit signing without an explicit reason.
- A PR that ships a `console.log` or leftover debug code.
- A PR with secrets, private keys, or `.env` contents committed.

## License of contributions

By submitting a PR you agree your contribution is licensed under the same terms as the file you are modifying - BUSL-1.1 for the hook (`src/WoolFiHook.sol`, with a two-year MIT conversion matching Uniswap v4) and MIT for everything else.

## Code of conduct

Be technical, be direct, push back with substance when you disagree. Personal attacks, harassment, and bad-faith engagement get you removed without warning. We do not need a 4,000-word document to know this.
