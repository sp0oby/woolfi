import {describe, expect, it} from "vitest";

import {contractSource} from "./deployment";
import {parseVaultPools} from "./vaults";

const VAULT_A = "0x1111111111111111111111111111111111111111";
const VAULT_B = "0x2222222222222222222222222222222222222222";
const POOL_A = `0x${"a".repeat(64)}`;
const POOL_B = `0x${"b".repeat(64)}`;

describe("parseVaultPools", () => {
  it("keeps codegen usable with a zero placeholder when unset", () => {
    expect(parseVaultPools(undefined)).toHaveLength(1);
    expect(parseVaultPools("  ")[0].vault).toBe("0x0000000000000000000000000000000000000000");
  });

  it("parses vault=poolId pairs", () => {
    expect(parseVaultPools(`${VAULT_A}=${POOL_A}, ${VAULT_B}=${POOL_B}`)).toEqual([
      {vault: VAULT_A, poolId: POOL_A},
      {vault: VAULT_B, poolId: POOL_B},
    ]);
  });

  it("rejects malformed, invalid and duplicate entries", () => {
    expect(() => parseVaultPools(VAULT_A)).toThrow(/must be vault=poolId/);
    expect(() => parseVaultPools(`0x12=${POOL_A}`)).toThrow(/invalid vault address/);
    expect(() => parseVaultPools(`${VAULT_A}=0x12`)).toThrow(/invalid bytes32 pool ID/);
    expect(() => parseVaultPools(`${VAULT_A}=${POOL_A},${VAULT_A}=${POOL_B}`)).toThrow(/duplicate vault/);
    expect(() => parseVaultPools(`${VAULT_A}=${POOL_A},${VAULT_B}=${POOL_A.toUpperCase().replace("0X", "0x")}`)).toThrow(
      /duplicate pool ID/,
    );
  });
});

describe("contractSource (pre-launch manifest)", () => {
  it("falls back to env values while the manifest is not live", () => {
    expect(contractSource("hook", VAULT_A, "123")).toEqual({address: VAULT_A, startBlock: 123});
  });

  it("uses the manifest's zero address and block when env is unset", () => {
    const source = contractSource("positionManager", undefined, undefined);
    expect(source.address).toBe("0x0000000000000000000000000000000000000000");
    expect(source.startBlock).toBe(0);
  });
});
