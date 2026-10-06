# RPC providers for Robinhood Chain (4663)

Verified on 2026-10-06. Re-check before launch; provider support changes.

## Support matrix

| Provider | 4663 mainnet | Archive | WebSocket | Free tier | Source |
|---|---|---|---|---|---|
| Alchemy | Yes (Robinhood's "recommended RPC provider") | Yes | Yes | 30M CU/month, 500 CU/s (~25 req/s) | [docs.robinhood.com/chain](https://docs.robinhood.com/chain/), [alchemy.com/pricing](https://www.alchemy.com/pricing) |
| QuickNode | Yes | Yes ("full archive, no pruning") | Yes (`eth_subscribe`) | Yes, no card; limits not confirmed | [quicknode.com/chains/robinhood](https://www.quicknode.com/chains/robinhood) |
| dRPC | Yes (named by Robinhood as supported) | not confirmed | not confirmed | not confirmed (pricing page did not render) | [drpc.org/chainlist/robinhood](https://drpc.org/chainlist/robinhood) |
| Infura | not confirmed | - | - | - | not listed by Robinhood |
| Ankr | not confirmed | - | - | - | not listed by Robinhood |
| Chainstack | not confirmed | - | - | - | not listed by Robinhood |
| GetBlock | not confirmed | - | - | - | not listed by Robinhood |
| Conduit | not confirmed | - | - | - | not listed by Robinhood |

Robinhood also names Blockdaemon and Validation Cloud as supported providers (per [QuickNode's provider roundup](https://www.quicknode.com/builders-guide/best/top-10-robinhood-chain-rpc-providers) citing Robinhood docs); not independently confirmed.

Chainlist ([chainlist.org](https://chainlist.org/rpcs.json)) lists further community endpoints (publicnode, Pocket, Tatum, bloXroute, Nodeflare, Globalstake). `robinhood-rpc.publicnode.com` returned HTTP 403 from a scripted client on 2026-10-06. Do not depend on community endpoints for production.

## Public RPC measurement

`https://rpc.mainnet.chain.robinhood.com`, 20 sequential `eth_blockNumber` calls with `User-Agent: Mozilla/5.0` (it returns 403 without a UA header):

- 0 errors, 0 rate-limit responses
- latency min 92 ms, p50 118 ms, p95 138 ms, max 151 ms
- **Not archive.** `eth_getBalance` at block 1 returned `historical state ... is not available`.

Conclusion: fine for frontend reads and as a monitoring cross-check. Unsuitable for the Ponder indexer, which backfills from each contract's start block. Published rate limits: not confirmed.

## Rough cost at ~5 req/s sustained

5 req/s is ~13M requests/month. At a blended ~20 CU/request (mix of `eth_blockNumber`, `eth_call`, `eth_getLogs`), that is ~260M CU/month. On Alchemy pay-as-you-go ($0.525 per 1M CU, first 30M free) that is roughly **$120/month**. This is an estimate, not a quote; measure real CU use in the first week. QuickNode and dRPC paid pricing: not confirmed.

## Recommendation

| Role | Provider | Why |
|---|---|---|
| Indexer (Ponder) | **Alchemy** (paid PAYG) | Robinhood's recommended provider; archive confirmed; high throughput for backfill |
| Keeper | **QuickNode** (free tier to start) | Archive + WebSocket confirmed; keeps keeper on a different vendor than the indexer so one outage does not stop both |
| Monitoring cross-check | **Public Robinhood RPC** | Independent operator from both of the above; head-block comparison does not need archive |

Frontend: set `NEXT_PUBLIC_ROBINHOOD_RPC_URL` to a domain-restricted Alchemy key, with the public RPC as wagmi fallback.

## Env wiring

- Indexer: `PONDER_RPC_URL_ROBINHOOD=<alchemy https url>`
- Keeper: `ROBINHOOD_RPC_URL=<quicknode https url>`
- CI fork tests: GitHub secret `ROBINHOOD_RPC_URL` (any of the above)
- Never commit provider keys.
