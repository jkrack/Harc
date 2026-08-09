import { DurableObject } from "cloudflare:workers";

const PRODUCER_NAME = "harc-remote-relay-staging";
const SUMMARY_NAME = "qualification";
const REPORT_PATH = "/report";
const RESET_PATH = "/reset";

const sensitiveHeaderNames = new Set([
  "authorization",
  "cookie",
  "x-harc-relay-capability",
  "x-harc-relay-device-route",
  "x-harc-relay-role",
  "x-harc-relay-session-id",
]);

const plaintextMarkers = [
  "HARC-REDACTION-CANARY-INVITATION",
  "HARC-REDACTION-CANARY-DEVICE-KEY",
  "HARC-REDACTION-CANARY-HOST-NAME",
  "HARC-REDACTION-CANARY-RECORDING-NAME",
  "HARC-REDACTION-CANARY-TRANSCRIPT",
  "HARC-REDACTION-CANARY-AUDIO",
] as const;

export interface RedactionDelta {
  batches: number;
  producerEvents: number;
  ignoredProducerEvents: number;
  fetchEvents: number;
  nonFetchEvents: number;
  healthEndpoints: number;
  hostConnectEndpoints: number;
  hostSessionEndpoints: number;
  sessionConnectEndpoints: number;
  otherEndpoints: number;
  requestHeaderFieldsDiscarded: number;
  sensitiveHeaderOccurrencesDiscarded: number;
  canaryHeaderOccurrencesDiscarded: number;
  cfMetadataObjectsDiscarded: number;
  requestPlaintextMarkersDiscarded: number;
  logAndExceptionPlaintextMarkers: number;
  logRecords: number;
  exceptionRecords: number;
  diagnosticRecords: number;
  truncatedEvents: number;
  nonOkOutcomes: number;
}

export type RedactionReport = RedactionDelta & {
  schemaVersion: 1;
};

export class RedactionSummary extends DurableObject<RedactionObserverEnv> {
  constructor(ctx: DurableObjectState, env: RedactionObserverEnv) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS redaction_summary (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          schema_version INTEGER NOT NULL CHECK (schema_version = 1),
          batches INTEGER NOT NULL,
          producer_events INTEGER NOT NULL,
          ignored_producer_events INTEGER NOT NULL,
          fetch_events INTEGER NOT NULL,
          non_fetch_events INTEGER NOT NULL,
          health_endpoints INTEGER NOT NULL,
          host_connect_endpoints INTEGER NOT NULL,
          host_session_endpoints INTEGER NOT NULL,
          session_connect_endpoints INTEGER NOT NULL,
          other_endpoints INTEGER NOT NULL,
          request_header_fields_discarded INTEGER NOT NULL,
          sensitive_header_occurrences_discarded INTEGER NOT NULL,
          canary_header_occurrences_discarded INTEGER NOT NULL,
          cf_metadata_objects_discarded INTEGER NOT NULL,
          request_plaintext_markers_discarded INTEGER NOT NULL,
          log_exception_plaintext_markers INTEGER NOT NULL,
          log_records INTEGER NOT NULL,
          exception_records INTEGER NOT NULL,
          diagnostic_records INTEGER NOT NULL,
          truncated_events INTEGER NOT NULL,
          non_ok_outcomes INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO redaction_summary VALUES (
          1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        );
      `);
    });
  }

  async record(delta: RedactionDelta): Promise<void> {
    assertDelta(delta);
    this.ctx.storage.sql.exec(`
      UPDATE redaction_summary SET
        batches = batches + ?,
        producer_events = producer_events + ?,
        ignored_producer_events = ignored_producer_events + ?,
        fetch_events = fetch_events + ?,
        non_fetch_events = non_fetch_events + ?,
        health_endpoints = health_endpoints + ?,
        host_connect_endpoints = host_connect_endpoints + ?,
        host_session_endpoints = host_session_endpoints + ?,
        session_connect_endpoints = session_connect_endpoints + ?,
        other_endpoints = other_endpoints + ?,
        request_header_fields_discarded = request_header_fields_discarded + ?,
        sensitive_header_occurrences_discarded = sensitive_header_occurrences_discarded + ?,
        canary_header_occurrences_discarded = canary_header_occurrences_discarded + ?,
        cf_metadata_objects_discarded = cf_metadata_objects_discarded + ?,
        request_plaintext_markers_discarded = request_plaintext_markers_discarded + ?,
        log_exception_plaintext_markers = log_exception_plaintext_markers + ?,
        log_records = log_records + ?,
        exception_records = exception_records + ?,
        diagnostic_records = diagnostic_records + ?,
        truncated_events = truncated_events + ?,
        non_ok_outcomes = non_ok_outcomes + ?
      WHERE id = 1
    `,
    delta.batches,
    delta.producerEvents,
    delta.ignoredProducerEvents,
    delta.fetchEvents,
    delta.nonFetchEvents,
    delta.healthEndpoints,
    delta.hostConnectEndpoints,
    delta.hostSessionEndpoints,
    delta.sessionConnectEndpoints,
    delta.otherEndpoints,
    delta.requestHeaderFieldsDiscarded,
    delta.sensitiveHeaderOccurrencesDiscarded,
    delta.canaryHeaderOccurrencesDiscarded,
    delta.cfMetadataObjectsDiscarded,
    delta.requestPlaintextMarkersDiscarded,
    delta.logAndExceptionPlaintextMarkers,
    delta.logRecords,
    delta.exceptionRecords,
    delta.diagnosticRecords,
    delta.truncatedEvents,
    delta.nonOkOutcomes);
  }

  report(): RedactionReport {
    const row = this.ctx.storage.sql.exec<SummaryRow>(
      "SELECT * FROM redaction_summary WHERE id = 1",
    ).one();
    return rowToReport(row);
  }

  reset(): void {
    this.ctx.storage.sql.exec(`
      UPDATE redaction_summary SET
        batches = 0,
        producer_events = 0,
        ignored_producer_events = 0,
        fetch_events = 0,
        non_fetch_events = 0,
        health_endpoints = 0,
        host_connect_endpoints = 0,
        host_session_endpoints = 0,
        session_connect_endpoints = 0,
        other_endpoints = 0,
        request_header_fields_discarded = 0,
        sensitive_header_occurrences_discarded = 0,
        canary_header_occurrences_discarded = 0,
        cf_metadata_objects_discarded = 0,
        request_plaintext_markers_discarded = 0,
        log_exception_plaintext_markers = 0,
        log_records = 0,
        exception_records = 0,
        diagnostic_records = 0,
        truncated_events = 0,
        non_ok_outcomes = 0
      WHERE id = 1
    `);
  }
}

export default {
  async fetch(request: Request, env: RedactionObserverEnv): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    const summary = env.REDACTION_SUMMARY.getByName(SUMMARY_NAME);

    if (request.method === "GET" && pathname === "/health") {
      return safeJSON({ status: "ok" });
    }
    if (request.method === "GET" && pathname === REPORT_PATH) {
      return safeJSON(await summary.report());
    }
    if (request.method === "POST" && pathname === RESET_PATH &&
        hasEmptyBody(request)) {
      await summary.reset();
      return safeJSON({ status: "reset" });
    }
    return safeJSON({ code: "not_found" }, 404);
  },

  async tail(
    events: TraceItem[],
    env: RedactionObserverEnv,
    ctx: ExecutionContext,
  ): Promise<void> {
    const delta = summarizeTailEvents(events);
    ctx.waitUntil(
      env.REDACTION_SUMMARY.getByName(SUMMARY_NAME).record(delta),
    );
  },
} satisfies ExportedHandler<RedactionObserverEnv>;

export function summarizeTailEvents(events: TraceItem[]): RedactionDelta {
  const delta = emptyDelta();
  delta.batches = 1;

  for (const item of events) {
    if (item.scriptName !== PRODUCER_NAME) {
      delta.ignoredProducerEvents += 1;
      continue;
    }
    delta.producerEvents += 1;
    delta.logRecords += item.logs.length;
    delta.exceptionRecords += item.exceptions.length;
    delta.diagnosticRecords += item.diagnosticsChannelEvents.length;
    delta.truncatedEvents += item.truncated ? 1 : 0;
    delta.nonOkOutcomes += item.outcome === "ok" ? 0 : 1;
    delta.logAndExceptionPlaintextMarkers += markerOccurrences([
      ...item.logs.map((log) => boundedString(log.message)),
      ...item.exceptions.map((exception) => exception.message),
    ]);

    const request = fetchRequest(item.event);
    if (request === null) {
      delta.nonFetchEvents += 1;
      continue;
    }
    delta.fetchEvents += 1;
    const headerEntries = Object.entries(request.headers);
    delta.requestHeaderFieldsDiscarded += headerEntries.length;
    delta.sensitiveHeaderOccurrencesDiscarded += headerEntries.filter(
      ([name]) => sensitiveHeaderNames.has(name.toLowerCase()),
    ).length;
    delta.canaryHeaderOccurrencesDiscarded += headerEntries.filter(
      ([name]) => /^x-harc-redaction-[1-6]$/u.test(name.toLowerCase()),
    ).length;
    delta.cfMetadataObjectsDiscarded += request.cf === undefined ? 0 : 1;
    delta.requestPlaintextMarkersDiscarded += markerOccurrences([
      request.url,
      ...headerEntries.map(([, value]) => value),
    ]);
    classifyEndpoint(request.url, delta);
  }

  return delta;
}

function fetchRequest(
  event: TraceItem["event"],
): TraceItemFetchEventInfoRequest | null {
  if (event === null || !("request" in event)) {
    return null;
  }
  return event.request.getUnredacted();
}

function classifyEndpoint(urlText: string, delta: RedactionDelta): void {
  let pathname: string;
  try {
    pathname = new URL(urlText).pathname;
  } catch {
    delta.otherEndpoints += 1;
    return;
  }
  if (pathname === "/health") {
    delta.healthEndpoints += 1;
  } else if (/^\/v1\/hosts\/[A-Za-z0-9_-]{43}\/connect$/u.test(pathname)) {
    delta.hostConnectEndpoints += 1;
  } else if (/^\/v1\/hosts\/[A-Za-z0-9_-]{43}\/sessions$/u.test(pathname)) {
    delta.hostSessionEndpoints += 1;
  } else if (/^\/v1\/sessions\/[A-Za-z0-9_-]{43}\/connect$/u.test(pathname)) {
    delta.sessionConnectEndpoints += 1;
  } else {
    delta.otherEndpoints += 1;
  }
}

function markerOccurrences(values: string[]): number {
  let count = 0;
  for (const value of values) {
    for (const marker of plaintextMarkers) {
      count += value.includes(marker) ? 1 : 0;
    }
  }
  return count;
}

function boundedString(value: unknown): string {
  if (typeof value === "string") {
    return value.slice(0, 16_384);
  }
  try {
    return (JSON.stringify(value) ?? "").slice(0, 16_384);
  } catch {
    return "";
  }
}

function emptyDelta(): RedactionDelta {
  return {
    batches: 0,
    producerEvents: 0,
    ignoredProducerEvents: 0,
    fetchEvents: 0,
    nonFetchEvents: 0,
    healthEndpoints: 0,
    hostConnectEndpoints: 0,
    hostSessionEndpoints: 0,
    sessionConnectEndpoints: 0,
    otherEndpoints: 0,
    requestHeaderFieldsDiscarded: 0,
    sensitiveHeaderOccurrencesDiscarded: 0,
    canaryHeaderOccurrencesDiscarded: 0,
    cfMetadataObjectsDiscarded: 0,
    requestPlaintextMarkersDiscarded: 0,
    logAndExceptionPlaintextMarkers: 0,
    logRecords: 0,
    exceptionRecords: 0,
    diagnosticRecords: 0,
    truncatedEvents: 0,
    nonOkOutcomes: 0,
  };
}

interface SummaryRow {
  [key: string]: SqlStorageValue;
  schema_version: number;
  batches: number;
  producer_events: number;
  ignored_producer_events: number;
  fetch_events: number;
  non_fetch_events: number;
  health_endpoints: number;
  host_connect_endpoints: number;
  host_session_endpoints: number;
  session_connect_endpoints: number;
  other_endpoints: number;
  request_header_fields_discarded: number;
  sensitive_header_occurrences_discarded: number;
  canary_header_occurrences_discarded: number;
  cf_metadata_objects_discarded: number;
  request_plaintext_markers_discarded: number;
  log_exception_plaintext_markers: number;
  log_records: number;
  exception_records: number;
  diagnostic_records: number;
  truncated_events: number;
  non_ok_outcomes: number;
}

function rowToReport(row: SummaryRow): RedactionReport {
  return {
    schemaVersion: 1,
    batches: row.batches,
    producerEvents: row.producer_events,
    ignoredProducerEvents: row.ignored_producer_events,
    fetchEvents: row.fetch_events,
    nonFetchEvents: row.non_fetch_events,
    healthEndpoints: row.health_endpoints,
    hostConnectEndpoints: row.host_connect_endpoints,
    hostSessionEndpoints: row.host_session_endpoints,
    sessionConnectEndpoints: row.session_connect_endpoints,
    otherEndpoints: row.other_endpoints,
    requestHeaderFieldsDiscarded: row.request_header_fields_discarded,
    sensitiveHeaderOccurrencesDiscarded:
      row.sensitive_header_occurrences_discarded,
    canaryHeaderOccurrencesDiscarded:
      row.canary_header_occurrences_discarded,
    cfMetadataObjectsDiscarded: row.cf_metadata_objects_discarded,
    requestPlaintextMarkersDiscarded:
      row.request_plaintext_markers_discarded,
    logAndExceptionPlaintextMarkers:
      row.log_exception_plaintext_markers,
    logRecords: row.log_records,
    exceptionRecords: row.exception_records,
    diagnosticRecords: row.diagnostic_records,
    truncatedEvents: row.truncated_events,
    nonOkOutcomes: row.non_ok_outcomes,
  };
}

function assertDelta(delta: RedactionDelta): void {
  for (const [name, value] of Object.entries(delta)) {
    if (!Number.isSafeInteger(value) || value < 0 || value > 1_000_000) {
      throw new TypeError(`invalid aggregate ${name}`);
    }
  }
}

function safeJSON(value: object, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

function hasEmptyBody(request: Request): boolean {
  return request.body === null || request.headers.get("content-length") === "0";
}
