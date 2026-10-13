# WoolFi launch post

## Long version (X long-form post)

We've been building something new on Robinhood Chain using Uniswap v4 hooks. It's called WoolFi, a market for the spread.

Every pool has two prices: the price inside the pool, and the real price from Chainlink. The gap between them is the spread.

Most exchanges charge the same fee no matter which way you trade. WoolFi doesn't.

Our v4 hook checks the real price on every single swap:

- Trade toward the real price, and you pay a lower fee.
- Trade away from it, and you pay a higher fee.

So the market keeps pulling itself back in line, all on its own. No one has to babysit the pool.

Who is it for?

Traders: swap Robinhood stock tokens like NVDA, MSTR, SPY and TSLA against USDG or WETH, or trade one stock against another, like SPY/QQQ or AAPL/MSFT.

Liquidity providers: add liquidity and earn the trading fees, with no ranges to manage. Already providing liquidity on Uniswap v3? Move your position over in one click.

Underwriters: stake URU behind a pool for a cut of its fees. In return, your stake backs the pool if a stock and its price feed ever break apart.

It's built around real market hours. Stock tokens only get fresh prices while the NYSE is open (9:30am to 4pm ET, Monday to Friday), so WoolFi follows the same clock:

- While the market is open, the smart fees are on.
- After the close, on weekends and on market holidays, fees go flat and new deposits wait for the open, so nobody gets picked off on stale prices. Swaps and withdrawals keep working.
- For the first 15 minutes after the open, fees stay flat while prices settle.

WETH/USDG trades 24/7.

Urufu Gemu holders get 15% of their fees back.

18 pools, all launching together.

Coming soon to Robinhood Chain, powered by Uniswap.

## Short version (fits in 280 characters)

WoolFi: a market for the spread, on Uniswap v4 hooks.

Trade toward the real price and pay less, trade away and pay more.

Stock pools follow NYSE hours, with flat fees while the market is closed.

Trade, LP or underwrite with URU across 18 pools. Coming soon to Robinhood Chain.
