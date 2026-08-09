import { describe, expect, it } from "vitest";

import {
  MAX_PAIRING_CAPABILITY_LIFETIME_MS,
  parseHostControlCommand,
} from "../src/protocol";
import { hashOpaqueToken, randomOpaqueToken } from "../src/security";

describe("Host control protocol", () => {
  it("accepts a bounded exact pairing authorization", async () => {
    const now = Date.now();
    const command = {
      type: "authorize",
      routeID: randomOpaqueToken(),
      capabilityHash: await hashOpaqueToken(randomOpaqueToken()),
      kind: "pairing",
      expiresAt: now + MAX_PAIRING_CAPABILITY_LIFETIME_MS,
    };

    expect(parseHostControlCommand(JSON.stringify(command), now)).toEqual(command);
  });

  it("rejects unknown fields and overlong pairing life", async () => {
    const now = Date.now();
    const base = {
      type: "authorize",
      routeID: randomOpaqueToken(),
      capabilityHash: await hashOpaqueToken(randomOpaqueToken()),
      kind: "pairing",
      expiresAt: now + MAX_PAIRING_CAPABILITY_LIFETIME_MS,
    };

    expect(parseHostControlCommand(
      JSON.stringify({ ...base, deviceName: "must-not-cross" }),
      now,
    )).toBeNull();
    expect(parseHostControlCommand(
      JSON.stringify({
        ...base,
        expiresAt: now + MAX_PAIRING_CAPABILITY_LIFETIME_MS + 1,
      }),
      now,
    )).toBeNull();
  });
});
