import {describe, expect, it} from "vitest";

import {gemuEligibilityText} from "./rebate";

describe("gemuEligibilityText", () => {
  it("asks to connect first", () => {
    expect(gemuEligibilityText({connected: false})).toEqual({text: "Connect wallet to check", eligible: false});
  });

  it("is eligible only with a non-zero NFT balance", () => {
    expect(gemuEligibilityText({connected: true, balance: 0n}).eligible).toBe(false);
    expect(gemuEligibilityText({connected: true, balance: 1n})).toEqual({
      text: "Eligible · holds 1 Urufu Gemu NFT",
      eligible: true,
    });
    expect(gemuEligibilityText({connected: true, balance: 3n}).text).toBe("Eligible · holds 3 Urufu Gemu NFTs");
  });

  it("never claims eligibility while loading or after a failed read", () => {
    expect(gemuEligibilityText({connected: true, isLoading: true, balance: 2n}).eligible).toBe(false);
    expect(gemuEligibilityText({connected: true, isError: true}).text).toBe("Could not check NFT balance");
  });
});
