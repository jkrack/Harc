import { describe, expect, it } from "vitest";

import {
  constantTimeEqual,
  hashOpaqueToken,
  isOpaqueToken,
  randomOpaqueToken,
  tokenMatchesHash,
} from "../src/security";

describe("relay capability helpers", () => {
  it("generates independent canonical 256-bit tokens", () => {
    const first = randomOpaqueToken();
    const second = randomOpaqueToken();

    expect(first).not.toBe(second);
    expect(isOpaqueToken(first)).toBe(true);
    expect(isOpaqueToken(second)).toBe(true);
  });

  it("matches only the exact capability", async () => {
    const capability = randomOpaqueToken();
    const hash = await hashOpaqueToken(capability);

    expect(await tokenMatchesHash(capability, hash)).toBe(true);
    expect(await tokenMatchesHash(randomOpaqueToken(), hash)).toBe(false);
    expect(await tokenMatchesHash(capability.slice(1), hash)).toBe(false);
  });

  it("rejects malformed tokens and unequal strings", () => {
    expect(isOpaqueToken("not-a-token")).toBe(false);
    expect(isOpaqueToken("B".repeat(43))).toBe(false);
    expect(constantTimeEqual("same", "same")).toBe(true);
    expect(constantTimeEqual("same", "different")).toBe(false);
    expect(constantTimeEqual("same", "samf")).toBe(false);
  });
});
