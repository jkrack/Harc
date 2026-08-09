import { describe, expect, it } from "vitest";

import { summarizeTailEvents } from "../src/redaction-observer";

describe("redaction observer", () => {
  it("reduces request secrets and plaintext canaries to aggregate counts", () => {
    const canary = "HARC-REDACTION-CANARY-TRANSCRIPT";
    const secret = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG";
    const item = fetchItem({
      url: "https://staging.example/v1/hosts/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG/connect",
      headers: {
        "x-harc-relay-capability": secret,
        "x-qualification-canary": canary,
        "user-agent": "test",
      },
    });

    const summary = summarizeTailEvents([item]);

    expect(summary.producerEvents).toBe(1);
    expect(summary.fetchEvents).toBe(1);
    expect(summary.hostConnectEndpoints).toBe(1);
    expect(summary.requestHeaderFieldsDiscarded).toBe(3);
    expect(summary.sensitiveHeaderOccurrencesDiscarded).toBe(1);
    expect(summary.canaryHeaderOccurrencesDiscarded).toBe(0);
    expect(summary.cfMetadataObjectsDiscarded).toBe(1);
    expect(summary.requestPlaintextMarkersDiscarded).toBe(1);
    expect(summary.logAndExceptionPlaintextMarkers).toBe(0);

    const serialized = JSON.stringify(summary);
    expect(serialized).not.toContain(canary);
    expect(serialized).not.toContain(secret);
    expect(serialized).not.toContain("x-harc-relay-capability");
    expect(serialized).not.toContain("user-agent");
    expect(serialized).not.toContain("/v1/hosts/");
  });

  it("counts unsafe producer logs without retaining their values", () => {
    const marker = "HARC-REDACTION-CANARY-RECORDING-NAME";
    const item = fetchItem({
      url: "https://staging.example/health",
      headers: {},
      logs: [{ timestamp: 1, level: "log", message: [marker] }],
      exceptions: [{ timestamp: 2, name: "Error", message: marker }],
      outcome: "exception",
      truncated: true,
    });

    const summary = summarizeTailEvents([item]);

    expect(summary.logAndExceptionPlaintextMarkers).toBe(2);
    expect(summary.logRecords).toBe(1);
    expect(summary.exceptionRecords).toBe(1);
    expect(summary.nonOkOutcomes).toBe(1);
    expect(summary.truncatedEvents).toBe(1);
    expect(JSON.stringify(summary)).not.toContain(marker);
  });

  it("counts named canary headers without retaining names or values", () => {
    const marker = "HARC-REDACTION-CANARY-DEVICE-KEY";
    const summary = summarizeTailEvents([fetchItem({
      url: "https://staging.example/redaction-canary",
      headers: { "x-harc-redaction-2": marker },
    })]);

    expect(summary.canaryHeaderOccurrencesDiscarded).toBe(1);
    expect(summary.requestPlaintextMarkersDiscarded).toBe(1);
    expect(JSON.stringify(summary)).not.toContain("x-harc-redaction-2");
    expect(JSON.stringify(summary)).not.toContain(marker);
  });

  it("ignores unrelated producers and categorizes non-fetch events", () => {
    const unrelated = fetchItem({
      scriptName: "another-worker",
      url: "https://example.test/health",
      headers: {},
    });
    const alarm = traceItem({ event: { scheduledTime: new Date(0) } });

    const summary = summarizeTailEvents([unrelated, alarm]);

    expect(summary.ignoredProducerEvents).toBe(1);
    expect(summary.producerEvents).toBe(1);
    expect(summary.nonFetchEvents).toBe(1);
  });
});

interface FetchItemOptions {
  url: string;
  headers: Record<string, string>;
  scriptName?: string;
  logs?: TraceLog[];
  exceptions?: TraceException[];
  outcome?: string;
  truncated?: boolean;
}

function fetchItem(options: FetchItemOptions): TraceItem {
  const request: TraceItemFetchEventInfoRequest = {
    url: options.url,
    method: "GET",
    headers: options.headers,
    cf: { colo: "test" },
    getUnredacted: () => request,
  };
  return traceItem({
    scriptName: options.scriptName ?? "harc-remote-relay-staging",
    event: { request, response: { status: 200 } },
    logs: options.logs ?? [],
    exceptions: options.exceptions ?? [],
    outcome: options.outcome ?? "ok",
    truncated: options.truncated ?? false,
  });
}

function traceItem(overrides: Partial<TraceItem>): TraceItem {
  return {
    event: null,
    eventTimestamp: 0,
    logs: [],
    exceptions: [],
    diagnosticsChannelEvents: [],
    scriptName: "harc-remote-relay-staging",
    outcome: "ok",
    executionModel: "stateless",
    truncated: false,
    cpuTime: 0,
    wallTime: 0,
    ...overrides,
  };
}
