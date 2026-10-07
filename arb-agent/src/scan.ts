import {erc20Abi, executorAbi, hookAbi, oracleAbi, quoterV2Abi, v3FactoryAbi, v3PoolAbi} from "./abi.js";
import type {Address, AgentConfig, ArbPool} from "./config.js";
import {type Candidate, correctiveDirection, pickBest, tokenUnitsToUsd, usdToTokenUnits} from "./math.js";

const ZERO = "0x0000000000000000000000000000000000000000";
const V3_FEES = [100, 500, 3000, 10000] as const;
const ETH_USD_FEED = "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" as const;
const aggregatorAbi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {type: "uint80"},
      {type: "int256"},
      {type: "uint256"},
      {type: "uint256"},
      {type: "uint80"},
    ],
  },
] as const;

/** The subset of a viem client the agent needs. Injected so tests can mock the chain. */
export type ChainReader = {
  readContract: (args: Record<string, unknown>) => Promise<unknown>;
  simulateContract: (args: Record<string, unknown>) => Promise<{result: unknown; request: Record<string, unknown>}>;
  estimateContractGas: (args: Record<string, unknown>) => Promise<bigint>;
  getGasPrice: () => Promise<bigint>;
};
export type ChainWriter = {writeContract: (request: Record<string, unknown>) => Promise<`0x${string}`>};

export type PoolLog = {
  slug: string;
  driftBps: string;
  action: "idle" | "no-hedge-pool" | "no-executor" | "no-profit" | "simulated" | "executed" | "error";
  zeroForOne?: boolean;
  v3Fee?: number;
  v3DeviationBps?: number;
  amountIn?: string;
  profitUsd?: number;
  gasUsd?: number;
  hash?: `0x${string}`;
  error?: string;
};

const decimalsCache = new Map<string, number>();

async function decimals(chain: ChainReader, token: Address): Promise<number> {
  const k = token.toLowerCase();
  const hit = decimalsCache.get(k);
  if (hit !== undefined) return hit;
  const d = Number(await chain.readContract({address: token, abi: erc20Abi, functionName: "decimals"}));
  decimalsCache.set(k, d);
  return d;
}

/** Deepest Uniswap v3 pool for the pair by active liquidity, or null if none exists. */
export async function deepestV3Fee(chain: ChainReader, factory: Address, a: Address, b: Address): Promise<number | null> {
  let best: {fee: number; liq: bigint} | null = null;
  for (const fee of V3_FEES) {
    const pool = (await chain.readContract({address: factory, abi: v3FactoryAbi, functionName: "getPool", args: [a, b, fee]})) as Address;
    if (!pool || pool.toLowerCase() === ZERO) continue;
    const liq = (await chain.readContract({address: pool, abi: v3PoolAbi, functionName: "liquidity"})) as bigint;
    if (!best || liq > best.liq) best = {fee, liq};
  }
  return best && best.liq > 0n ? best.fee : null;
}

/**
 * One pool, one tick: read drift, pick the corrective direction, simulate the executor at each
 * candidate size, and (only when broadcasting and net profit clears the floor) send the best one.
 */
export async function scanPool(
  chain: ChainReader,
  writer: ChainWriter | undefined,
  pool: ArbPool,
  cfg: AgentConfig,
  sender: Address,
): Promise<PoolLog> {
  const drift = (await chain.readContract({address: pool.key.hooks, abi: hookAbi, functionName: "currentDrift", args: [pool.key]})) as bigint;
  const log: PoolLog = {slug: pool.slug, driftBps: drift.toString(), action: "idle"};
  const dir = correctiveDirection(drift, cfg.minDriftBps);
  if (!dir) return log;
  log.zeroForOne = dir.zeroForOne;

  const tokens = [pool.key.currency0, pool.key.currency1] as const;
  const oracles = [pool.oracle0, pool.oracle1] as const;
  const inIdx = dir.tokenInIndex;
  const outIdx = inIdx === 0 ? 1 : 0;
  const [priceIn, priceOut] = (await Promise.all([
    chain.readContract({address: oracles[inIdx], abi: oracleAbi, functionName: "getPrice"}),
    chain.readContract({address: oracles[outIdx], abi: oracleAbi, functionName: "getPrice"}),
  ])) as [bigint, bigint];
  const [decIn, decOut] = await Promise.all([decimals(chain, tokens[inIdx]), decimals(chain, tokens[outIdx])]);

  const v3Fee = await deepestV3Fee(chain, cfg.v3Factory, tokens[0], tokens[1]);
  if (v3Fee === null) return {...log, action: "no-hedge-pool"};
  log.v3Fee = v3Fee;
  log.v3DeviationBps = await v3Deviation(chain, cfg, tokens[outIdx], tokens[inIdx], v3Fee, priceOut, priceIn, decOut, decIn);

  if (!cfg.executor) return {...log, action: "no-executor"};

  const gasPrice = await chain.getGasPrice();
  const ethUsd = await ethUsdWad(chain);
  const candidates: Candidate[] = [];
  for (const usd of cfg.sizesUsd) {
    const amountIn = usdToTokenUnits(usd, priceIn, decIn);
    if (amountIn === 0n) continue;
    const args = [arbParams(pool, dir.zeroForOne, amountIn, v3Fee, 0n, tokens[inIdx], sender)];
    try {
      const sim = await chain.simulateContract({address: cfg.executor, abi: executorAbi, functionName: "execute", args, account: sender});
      const profit = sim.result as bigint;
      const gas = await chain.estimateContractGas({address: cfg.executor, abi: executorAbi, functionName: "execute", args, account: sender});
      candidates.push({
        amountIn,
        profit,
        profitUsd: tokenUnitsToUsd(profit, priceIn, decIn),
        gasCostUsd: tokenUnitsToUsd(gas * gasPrice, ethUsd, 18),
      });
    } catch {
      // A reverting size (no profit, hedge shortfall, guard) is simply not a candidate.
    }
  }

  const best = pickBest(candidates);
  if (!best) return {...log, action: "no-profit"};
  const net = best.profitUsd - best.gasCostUsd;
  const out: PoolLog = {...log, amountIn: best.amountIn.toString(), profitUsd: round(best.profitUsd), gasUsd: round(best.gasCostUsd), action: "simulated"};
  if (!cfg.broadcast || !writer || net < cfg.minProfitUsd) return out;

  // Send with a 5% haircut on the simulated profit as the on-chain floor.
  const minProfit = (best.profit * 95n) / 100n;
  const sim = await chain.simulateContract({
    address: cfg.executor,
    abi: executorAbi,
    functionName: "execute",
    args: [arbParams(pool, dir.zeroForOne, best.amountIn, v3Fee, minProfit, tokens[inIdx], sender)],
    account: sender,
  });
  const hash = await writer.writeContract(sim.request);
  return {...out, action: "executed", hash};
}

function arbParams(pool: ArbPool, zeroForOne: boolean, amountIn: bigint, v3Fee: number, minProfit: bigint, profitToken: Address, recipient: Address) {
  return {
    woolfiKey: pool.key,
    zeroForOne,
    amountIn,
    v3Fee,
    minProfit,
    profitToken,
    recipient,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 120),
  };
}

/** How far the v3 hedge pool sits from Chainlink fair, from a ~$100 QuoterV2 probe (bps, for logs). */
async function v3Deviation(
  chain: ChainReader,
  cfg: AgentConfig,
  tokenOut: Address,
  tokenIn: Address,
  fee: number,
  priceOut: bigint,
  priceIn: bigint,
  decOut: number,
  decIn: number,
): Promise<number | undefined> {
  try {
    const probe = usdToTokenUnits(100, priceOut, decOut);
    const sim = await chain.simulateContract({
      address: cfg.v3Quoter,
      abi: quoterV2Abi,
      functionName: "quoteExactInputSingle",
      args: [{tokenIn: tokenOut, tokenOut: tokenIn, amountIn: probe, fee, sqrtPriceLimitX96: 0n}],
    });
    const [amountOut] = sim.result as readonly [bigint, bigint, number, bigint];
    const gotUsd = tokenUnitsToUsd(amountOut, priceIn, decIn);
    return Math.round((gotUsd / 100 - 1) * 10_000);
  } catch {
    return undefined;
  }
}

async function ethUsdWad(chain: ChainReader): Promise<bigint> {
  const r = (await chain.readContract({address: ETH_USD_FEED, abi: aggregatorAbi, functionName: "latestRoundData"})) as readonly [bigint, bigint, bigint, bigint, bigint];
  return r[1] * 10n ** 10n; // 8dp feed to WAD
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
