import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import { summarizeTailEvents } from "../src/redaction-observer";

describe("redaction observer Durable Object", () => {
  it("atomically stores and exposes only the aggregate report", async () => {
    const summary = env.REDACTION_SUMMARY.getByName("qualification");
    await summary.reset();

    const delta = summarizeTailEvents([]);
    delta.producerEvents = 2;
    delta.fetchEvents = 2;
    delta.requestHeaderFieldsDiscarded = 14;
    delta.sensitiveHeaderOccurrencesDiscarded = 3;
    delta.requestPlaintextMarkersDiscarded = 6;
    await summary.record(delta);
    await summary.record(delta);

    const response = await SELF.fetch("https://observer.example/report");
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const report = await response.json<{
      schemaVersion: number;
      batches: number;
      producerEvents: number;
      requestHeaderFieldsDiscarded: number;
      sensitiveHeaderOccurrencesDiscarded: number;
      canaryHeaderOccurrencesDiscarded: number;
      requestPlaintextMarkersDiscarded: number;
    }>();
    expect(report).toMatchObject({
      schemaVersion: 1,
      batches: 2,
      producerEvents: 4,
      requestHeaderFieldsDiscarded: 28,
      sensitiveHeaderOccurrencesDiscarded: 6,
      requestPlaintextMarkersDiscarded: 12,
    });

    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain("x-harc-relay-capability");
    expect(serialized).not.toContain("HARC-REDACTION-CANARY");

    const reset = await SELF.fetch("https://observer.example/reset", {
      method: "POST",
    });
    expect(reset.status).toBe(200);
    expect((await summary.report()).producerEvents).toBe(0);

    const rejected = await SELF.fetch("https://observer.example/reset", {
      method: "POST",
      headers: { "content-length": "1" },
      body: "x",
    });
    expect(rejected.status).toBe(404);
  });
});
