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

export function items<T>(payload: {items?: T[]} | T[] | undefined | null): T[] {
  if (!payload) return [];
  return Array.isArray(payload) ? payload : (payload.items ?? []);
}
