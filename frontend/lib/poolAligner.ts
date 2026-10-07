/**
 * An unseeded pool keeps its launch price while Chainlink moves. Deposits revert (OutOfBand) once the
 * pool is more than the tolerance band (5%) off fair, so before the FIRST deposit into an empty pool
 * the UI should send `poolAligner.align(key)`: free (no tokens move), permissionless, and a no-op when
 * the pool is already on fair. Pools with liquidity are corrected by arbitrage instead; align reverts.
 */
export type AlignInputs = {
  /** PoolManager liquidity for the pool (StateLibrary.getLiquidity). */
  liquidity: bigint;
  /** Hook `currentDrift(key)` in bps, or undefined when it could not be read. */
  driftBps: bigint | number | undefined;
  /** Whether an aligner is deployed (manifest `poolAligner`). */
  alignerDeployed: boolean;
};

export function needsAlign({liquidity, driftBps, alignerDeployed}: AlignInputs): boolean {
  if (!alignerDeployed || liquidity !== 0n || driftBps === undefined) return false;
  return BigInt(driftBps) !== 0n;
}
