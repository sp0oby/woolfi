"use client";

import {useCallback, useEffect, useRef, useState} from "react";

import {approvalCovers, type ApprovalTarget} from "@/lib/txGuards";

/**
 * Optimistic record of a confirmed approval, bridging the gap until the on-chain allowance read
 * catches up with the receipt. It remembers exactly what was approved ({token, spender, amount}
 * or an NFT id) and only vouches for actions that approval covers - a larger amount, another
 * token or another NFT falls back to the on-chain read. The allowance is refetched on confirm.
 */
export function useApprovalShadow(
  hash: `0x${string}` | undefined,
  isSuccess: boolean,
  refetch?: () => unknown,
) {
  const requested = useRef<ApprovalTarget | undefined>(undefined);
  const refetchRef = useRef(refetch);
  refetchRef.current = refetch;
  const [confirmed, setConfirmed] = useState<(ApprovalTarget & {hash: `0x${string}`}) | undefined>();

  useEffect(() => {
    if (!isSuccess || !hash || !requested.current || confirmed?.hash === hash) return;
    setConfirmed({...requested.current, hash});
    refetchRef.current?.();
  }, [isSuccess, hash, confirmed?.hash]);

  /** Call right before sending the approval transaction. */
  const request = useCallback((target: ApprovalTarget) => {
    requested.current = target;
  }, []);
  const covers = useCallback((wanted: ApprovalTarget | undefined) => approvalCovers(confirmed, wanted), [confirmed]);
  /** Drop the shadow once the approval has been spent, so only the on-chain read counts. */
  const clear = useCallback(() => setConfirmed(undefined), []);

  return {request, covers, clear};
}
