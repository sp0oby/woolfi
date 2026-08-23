# WoolFi frontend

Next.js interface for WoolFi's Uniswap v4 multi-pool market on Robinhood Chain. The catalog covers
Robinhood Stock Token/USDG, Stock Token/WETH, stock-token spread, and WETH/USDG pools. Pools are
shown as pending until their verified oracles and production deployments are ready.

## Stack

- Next.js 14 (App Router)
- Tailwind CSS 3.4
- wagmi + viem

No mock data is used in the application. Live pool state comes from Robinhood Chain; unavailable
or pending state is displayed explicitly.

## Run

```bash
npm install
npm run dev    # localhost:3000
```

## Style guardrails

Black canvas, off-white text, restrained accents, sans headlines, and mono data labels. Keep copy
pool-aware: never imply one canonical pair or one market-hours schedule.

## Routes

- `/` - Robinhood Chain product overview and catalog status.
- `/app` - searchable multi-pool dashboard with pending/live states.
- `/docs` - hook, pool category, market-hours, disclosure, and underwriting overview.
- `/governance` - v1 multisig administration.

## Product rules

- Robinhood Stock Tokens provide economic exposure, not ownership of underlying securities.
- Issuer terms and geographic restrictions apply; do not claim every holder completed KYC.
- URU is the underwriting asset. Do not describe URU as a governance voting token.
- Market hours are pool-specific. WETH/USDG is always open.
