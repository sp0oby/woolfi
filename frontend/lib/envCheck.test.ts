import {describe, expect, it} from "vitest";

import {productionEnvProblems} from "./envCheck.mjs";

const complete = {
  NEXT_PUBLIC_WC_PROJECT_ID: "abc123",
  NEXT_PUBLIC_INDEXER_URL: "https://indexer.example.com",
  NEXT_PUBLIC_SITE_URL: "https://example.com",
};

describe("productionEnvProblems", () => {
  it("passes a complete production env", () => {
    expect(productionEnvProblems(complete)).toEqual([]);
  });

  it("flags each missing or placeholder setting", () => {
    expect(productionEnvProblems({})).toHaveLength(3);
    expect(productionEnvProblems({...complete, NEXT_PUBLIC_WC_PROJECT_ID: "woolfi-dev"})[0]).toMatch(/WC_PROJECT_ID/);
    expect(productionEnvProblems({...complete, NEXT_PUBLIC_INDEXER_URL: "http://localhost:42069"})[0]).toMatch(/INDEXER_URL/);
  });

  it("accepts Vercel's production URL in place of NEXT_PUBLIC_SITE_URL", () => {
    const {NEXT_PUBLIC_SITE_URL: _omit, ...rest} = complete;
    expect(productionEnvProblems({...rest, VERCEL_PROJECT_PRODUCTION_URL: "woolfi.vercel.app"})).toEqual([]);
  });
});
