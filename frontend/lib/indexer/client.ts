export const DEFAULT_INDEXER_URL = "http://localhost:42069";
export const INDEXER_STALE_AFTER_SECONDS = 15 * 60;

export function indexerUrl(): string {
  return (process.env.NEXT_PUBLIC_INDEXER_URL ?? DEFAULT_INDEXER_URL).replace(/\/$/, "");
}

export async function indexerGraphql<T>(
  query: string,
  variables: Record<string, unknown> = {},
  signal?: AbortSignal,
): Promise<T> {
  const response = await fetch(`${indexerUrl()}/graphql`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({query, variables}),
    signal,
  });
  if (!response.ok) {
    throw new Error(`Indexer HTTP ${response.status}`);
  }
  const body = (await response.json()) as {data?: T; errors?: Array<{message: string}>};
  if (body.errors?.length) {
    throw new Error(body.errors.map((error) => error.message).join("; "));
  }
  if (!body.data) throw new Error("Indexer returned no data");
  return body.data;
}

/**
 * Timestamp (seconds) of the newest block the indexer has processed, from Ponder's `/status`
 * (`{[chain]: {id, block: {number, timestamp}}}`). This, not the newest swap, is what says
 * whether the indexer is keeping up: a quiet pool can go hours without a swap.
 */
export async function indexerHeadTimestamp(signal?: AbortSignal): Promise<number | undefined> {
  const response = await fetch(`${indexerUrl()}/status`, {signal});
  if (!response.ok) throw new Error(`Indexer HTTP ${response.status}`);
  const body = (await response.json()) as Record<string, {block?: {timestamp?: number}}>;
  const stamps = Object.values(body)
    .map((chain) => chain?.block?.timestamp)
    .filter((t): t is number => typeof t === "number" && t > 0);
  return stamps.length ? Math.max(...stamps) : undefined;
}

export function items<T>(payload: {items?: T[]} | T[] | undefined | null): T[] {
  if (!payload) return [];
  return Array.isArray(payload) ? payload : (payload.items ?? []);
}
