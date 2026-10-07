import {ponder} from "ponder:registry";
import {
  swap,
  structuralBreak,
  breakEpisode,
  poolBreakPointer,
  breakConfirmSetting,
  oracleSkew,
  poolSafety,
  lpMovement,
  feeRouting,
  vaultEvent,
  rebateEvent,
} from "ponder:schema";
import {poolIdForVault} from "../vaults";

/**
 * Event handlers for WoolFi. Each handler is idempotent on (tx hash, log index) so re-orgs
 * are safe. Drift is stored as a signed bigint in the same bps units the hook emits.
 */

function eventId(event: {transaction: {hash: string}; log: {logIndex: number}}) {
  return `${event.transaction.hash}-${event.log.logIndex}`;
}

function vaultIdentity(address: `0x${string}`) {
  return {vault: address, poolId: poolIdForVault(address)};
}

ponder.on("WoolFiHook:SwapProcessed", async ({event, context}) => {
  await context.db.insert(swap).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    driftBps: event.args.driftBps,
    asymmetricActive: event.args.asymmetricActive,
    structuralBreakTriggered: event.args.structuralBreakTriggered,
  });
});

type EpisodeOutcome = "open" | "confirmed" | "cleared" | "recovered" | "resolved";

/** Open episode for a pool, or undefined if none is open (e.g. indexing started mid-episode). */
async function openEpisode(context: any, poolId: `0x${string}`) {
  const pointer = await context.db.find(poolBreakPointer, {id: poolId});
  if (!pointer || !pointer.open) return undefined;
  return pointer.episodeId as string;
}

async function closeEpisode(
  context: any,
  poolId: `0x${string}`,
  outcome: EpisodeOutcome,
  fields: Record<string, unknown>,
) {
  const episodeId = await openEpisode(context, poolId);
  if (!episodeId) return;
  await context.db.update(breakEpisode, {id: episodeId}).set({...fields, outcome});
  await context.db.update(poolBreakPointer, {id: poolId}).set({open: false});
}

ponder.on("WoolFiHook:StructuralBreakTriggered", async ({event, context}) => {
  const id = eventId(event);
  await context.db.insert(breakEpisode).values({
    id,
    poolId: event.args.id,
    detectedAt: event.block.timestamp,
    detectedBlock: event.block.number,
    detectedDriftBps: event.args.driftBps,
    outcome: "open",
  });
  await context.db
    .insert(poolBreakPointer)
    .values({id: event.args.id, episodeId: id, open: true})
    .onConflictDoUpdate({episodeId: id, open: true});
  await context.db.insert(structuralBreak).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    driftBps: event.args.driftBps,
    resolved: false,
    cachedFairPriceWad: null,
  });
});

ponder.on("WoolFiHook:StructuralBreakTargetCached", async ({event, context}) => {
  const episodeId = await openEpisode(context, event.args.id);
  if (episodeId) {
    await context.db.update(breakEpisode, {id: episodeId}).set({cachedFairPriceWad: event.args.fairPriceWad});
  }
  await context.db.insert(structuralBreak).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    driftBps: 0n,
    resolved: false,
    cachedFairPriceWad: event.args.fairPriceWad,
  });
});

ponder.on("WoolFiHook:OracleSkewObserved", async ({event, context}) => {
  await context.db.insert(oracleSkew).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    updatedAt0: event.args.updatedAt0,
    updatedAt1: event.args.updatedAt1,
    maxSkew: Number(event.args.maxSkew),
  });
});

ponder.on("WoolFiHook:PoolSafetyUpdated", async ({event, context}) => {
  await context.db.insert(poolSafety).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    stabilizationSeconds: Number(event.args.stabilizationSeconds),
    maxOracleSkew: Number(event.args.maxOracleSkew),
  });
});

ponder.on("WoolFiHook:StructuralBreakConfirmed", async ({event, context}) => {
  // Confirmation keeps the episode open (containment continues until recovery or resolution).
  const episodeId = await openEpisode(context, event.args.id);
  if (!episodeId) return;
  await context.db.update(breakEpisode, {id: episodeId}).set({
    confirmedAt: event.block.timestamp,
    confirmedDriftBps: event.args.driftBps,
    outcome: "confirmed",
  });
});

ponder.on("WoolFiHook:DrawdownFailed", async ({event, context}) => {
  const episodeId = await openEpisode(context, event.args.id);
  if (!episodeId) return;
  await context.db.update(breakEpisode, {id: episodeId}).set({
    drawdownFailed: true,
    drawdownFailureReason: event.args.reason,
  });
});

ponder.on("WoolFiHook:StructuralBreakCleared", async ({event, context}) => {
  await closeEpisode(context, event.args.id, "cleared", {
    clearedAt: event.block.timestamp,
    clearedDriftBps: event.args.driftBps,
  });
});

ponder.on("WoolFiHook:StructuralBreakRecovered", async ({event, context}) => {
  await closeEpisode(context, event.args.id, "recovered", {
    recoveredAt: event.block.timestamp,
    recoveredDriftBps: event.args.driftBps,
  });
});

ponder.on("WoolFiHook:BreakConfirmSecondsSet", async ({event, context}) => {
  await context.db.insert(breakConfirmSetting).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    confirmSeconds: Number(event.args.confirmSeconds),
  });
});

ponder.on("WoolFiHook:StructuralBreakResolved", async ({event, context}) => {
  await closeEpisode(context, event.args.id, "resolved", {resolvedAt: event.block.timestamp});
  // Mark the most recent unresolved break for this pool as resolved.
  // (Logged as a separate row keyed by tx so re-orgs are idempotent.)
  await context.db.insert(structuralBreak).values({
    id: eventId(event),
    poolId: event.args.id,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    driftBps: 0n,
    resolved: true,
    cachedFairPriceWad: null,
  });
});

ponder.on("WoolFiPositionManager:Mint", async ({event, context}) => {
  await context.db.insert(lpMovement).values({
    id: eventId(event),
    // PM emits the share id (uint256 of the poolId bytes32) - cast back to hex for consistency
    poolId: `0x${event.args.id.toString(16).padStart(64, "0")}` as `0x${string}`,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    account: event.args.to,
    kind: "mint",
    liquidity: event.args.liquidity,
    amount0: event.args.amount0,
    amount1: event.args.amount1,
  });
});

ponder.on("WoolFiPositionManager:Burn", async ({event, context}) => {
  await context.db.insert(lpMovement).values({
    id: eventId(event),
    poolId: `0x${event.args.id.toString(16).padStart(64, "0")}` as `0x${string}`,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    account: event.args.from,
    kind: "burn",
    liquidity: event.args.liquidity,
    amount0: event.args.amount0,
    amount1: event.args.amount1,
  });
});

ponder.on("WoolFiPositionManager:FeesRouted", async ({event, context}) => {
  await context.db.insert(feeRouting).values({
    id: eventId(event),
    poolId: `0x${event.args.id.toString(16).padStart(64, "0")}` as `0x${string}`,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    vault0: event.args.vault0,
    vault1: event.args.vault1,
    treasury0: event.args.treasury0,
    treasury1: event.args.treasury1,
  });
});

ponder.on("WoolFiUnderwritingVault:Staked", async ({event, context}) => {
  await context.db.insert(vaultEvent).values({
    id: eventId(event),
    ...vaultIdentity(event.log.address),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    kind: "stake",
    user: event.args.user,
    amount: event.args.amount,
    shares: event.args.shares,
    totalStakedAfter: null,
  });
});

ponder.on("WoolFiUnderwritingVault:Unstaked", async ({event, context}) => {
  await context.db.insert(vaultEvent).values({
    id: eventId(event),
    ...vaultIdentity(event.log.address),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    kind: "unstake",
    user: event.args.user,
    amount: event.args.amount,
    shares: event.args.shares,
    totalStakedAfter: null,
  });
});

ponder.on("WoolFiUnderwritingVault:Drawdown", async ({event, context}) => {
  await context.db.insert(vaultEvent).values({
    id: eventId(event),
    ...vaultIdentity(event.log.address),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    kind: "drawdown",
    user: null,
    amount: event.args.seized,
    shares: null,
    totalStakedAfter: event.args.totalStakedAfter,
  });
});

ponder.on("UrufuFeeRebateDistributor:RouterSet", async ({event, context}) => {
  await context.db.insert(rebateEvent).values({
    id: eventId(event), blockNumber: event.block.number, timestamp: event.block.timestamp,
    kind: "router-set", router: event.args.router,
  });
});

ponder.on("UrufuFeeRebateDistributor:WeeklyCapSet", async ({event, context}) => {
  await context.db.insert(rebateEvent).values({
    id: eventId(event), blockNumber: event.block.number, timestamp: event.block.timestamp,
    kind: "cap-set", token: event.args.token, amount: event.args.cap,
  });
});

ponder.on("UrufuFeeRebateDistributor:Funded", async ({event, context}) => {
  await context.db.insert(rebateEvent).values({
    id: eventId(event), blockNumber: event.block.number, timestamp: event.block.timestamp,
    kind: "funded", trader: event.args.funder, token: event.args.token, amount: event.args.amount,
  });
});

ponder.on("UrufuFeeRebateDistributor:RebateAccrued", async ({event, context}) => {
  await context.db.insert(rebateEvent).values({
    id: eventId(event), blockNumber: event.block.number, timestamp: event.block.timestamp,
    kind: "accrued", trader: event.args.trader, poolId: event.args.poolId,
    token: event.args.token, amount: event.args.amount, week: event.args.week,
  });
});

ponder.on("UrufuFeeRebateDistributor:RebateClaimed", async ({event, context}) => {
  await context.db.insert(rebateEvent).values({
    id: eventId(event), blockNumber: event.block.number, timestamp: event.block.timestamp,
    kind: "claimed", trader: event.args.trader, token: event.args.token,
    recipient: event.args.recipient, amount: event.args.amount,
  });
});
