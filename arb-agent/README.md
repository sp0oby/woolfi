# WoolFi arbitrage agent

An open-source bot that earns money by keeping WoolFi pools priced correctly. It needs no
trading capital, only gas.

## What it does

Every WoolFi pool has a fair price from Chainlink. When a pool drifts away from that price (say
someone dumps WETH and WoolFi's WETH/USDG pool now prices WETH 6% too cheap), there is a gap
between WoolFi and the deep Uniswap v3 pool for the same pair.

The agent closes that gap in one transaction:

1. Buy the cheap side on WoolFi.
2. Sell it on the Uniswap v3 pool.
3. Keep the difference.

## Why it's profitable

WoolFi's hook charges a lower fee on trades that move a pool back toward fair, and a higher
fee on trades that push it away. The agent only ever makes the corrective trade, so it pays
the discounted fee. Pools stay close to fair, liquidity providers earn the fees, and the
agent earns the spread.

On a live Robinhood Chain fork, a WoolFi WETH/USDG pool knocked 6.6% below fair was
arbitraged with a 2,000 USDG trade for a 52.99 USDG profit, which moved the pool back to
within about 1% of fair (`test/fork/WoolFiArbExecutor.fork.t.sol`).

## Why it needs no capital

The trade runs through `WoolFiArbExecutor`, which uses Uniswap v4 flash accounting. Inside
one transaction it buys on WoolFi (owing the PoolManager), sells on v3, repays the
PoolManager, and sends you the profit. If the trade would not be profitable, the whole
transaction reverts and you only lose gas. The executor has no owner and holds no funds
between transactions.

## How it decides

Each tick, for every live pool, the agent:

- reads the pool's drift from the WoolFi hook and the two Chainlink prices;
- skips the pool if it is within `ARB_MIN_DRIFT_BPS` of fair;
- finds the deepest Uniswap v3 pool for the pair;
- simulates the full executor trade at each size in `ARB_SIZES_USD`;
- keeps the size with the best profit after gas;
- sends it only if `ARB_BROADCAST=true` and net profit is at least `ARB_MIN_PROFIT_USD`.

The on-chain floor is 95% of the simulated profit, so a trade that got worse between
simulation and inclusion reverts instead of losing money.

## Optional AI summaries

If you set `ANTHROPIC_API_KEY`, the agent periodically sends its recent logs to Claude and
prints a short plain-English summary: what it did, why, and anything unusual (a pool stuck
off fair, a thin hedge pool, gas eating profits). Summaries can also be posted to a webhook.
The AI never makes trading decisions; those come from deterministic simulation.

## Risks

- **Gas:** failed or unprofitable sends still cost gas. Keep `ARB_MIN_PROFIT_USD` above
  typical gas costs.
- **Competition:** other bots can take the same trade first. Your transaction then reverts
  (only gas lost).
- **Simulation drift:** prices can move between simulation and inclusion. The 95% floor
  bounds this; it does not remove it.
- **Smart-contract risk:** WoolFi and the executor are unaudited pre-launch software.
- **Key safety:** use a dedicated hot wallet holding only gas money.

## Run it

```bash
cd arb-agent
npm install
cp .env.example .env    # set ARB_EXECUTOR, optionally ARB_PRIVATE_KEY
npm start               # dry-run: logs simulated trades, sends nothing
```

Set `ARB_BROADCAST=true` (with `ARB_PRIVATE_KEY`) to trade. The agent does nothing until the
deployment manifest's `launchStatus` is `live`.

To deploy your own executor: `forge script script/DeployArbExecutor.s.sol` (see
`docs/robinhood-deployment.md`).

```bash
npm test         # unit tests
npm run typecheck
```
