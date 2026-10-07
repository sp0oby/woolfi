import type {PoolLog} from "./scan.js";

/**
 * Optional AI narrator. Sends recent decision logs to the Claude Messages API and returns a short
 * plain-English summary. It is NEVER in the trade-decision path: trading decisions are made by
 * deterministic simulation in scan.ts before this runs, and any API failure is logged and ignored.
 */
export type ExplainDeps = {
  fetch: typeof fetch;
  log: (line: string) => void;
};

const SYSTEM = [
  "You summarize logs from an arbitrage agent for WoolFi, a Uniswap v4 hook on Robinhood Chain.",
  "WoolFi discounts swaps that move a pool toward its Chainlink fair price. The agent buys the cheap",
  "side on WoolFi and sells it on a Uniswap v3 pool. driftBps is the WoolFi pool's distance from fair",
  "(negative = token0 cheap). v3DeviationBps is how far the v3 hedge pool sits from fair.",
  "Reply in exactly 3 plain-English sentences: what the agent did, why, and anything anomalous",
  "(a pool persistently off fair, a v3 hedge pool that looks thin or off fair, gas eating profits,",
  "repeated errors). No markdown, no advice, no speculation beyond the data.",
].join(" ");

export async function explain(
  logs: PoolLog[],
  opts: {apiKey?: string; webhook?: string; model?: string},
  deps: ExplainDeps = {fetch, log: (l) => console.log(l)},
): Promise<string | null> {
  if (!opts.apiKey || logs.length === 0) return null;
  try {
    const res = await deps.fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": opts.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: opts.model ?? "claude-sonnet-4-5",
        max_tokens: 300,
        system: SYSTEM,
        messages: [{role: "user", content: JSON.stringify(logs.slice(-60))}],
      }),
    });
    if (!res.ok) {
      deps.log(JSON.stringify({explain: "api-error", status: res.status}));
      return null;
    }
    const body = (await res.json()) as {content?: {type: string; text?: string}[]};
    const summary = (body.content ?? []).filter((c) => c.type === "text").map((c) => c.text ?? "").join(" ").trim();
    if (!summary) return null;
    deps.log(JSON.stringify({explain: summary}));
    if (opts.webhook) {
      try {
        await deps.fetch(opts.webhook, {
          method: "POST",
          headers: {"content-type": "application/json"},
          body: JSON.stringify({summary, logs: logs.length}),
        });
      } catch (error) {
        deps.log(JSON.stringify({explain: "webhook-failed", error: String(error)}));
      }
    }
    return summary;
  } catch (error) {
    deps.log(JSON.stringify({explain: "failed", error: error instanceof Error ? error.message : String(error)}));
    return null;
  }
}
