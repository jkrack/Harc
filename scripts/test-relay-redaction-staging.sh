#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_ROOT="$PROJECT_ROOT/CloudflareRelay"
STAGING_ORIGIN="https://harc-remote-relay-staging.jlworker.workers.dev"
OBSERVER_NAME="harc-remote-redaction-observer"
OBSERVER_ORIGIN="https://harc-remote-redaction-observer.jlworker.workers.dev"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_DIR="$(mktemp -d "$TEMP_ROOT/harc-relay-redaction.XXXXXX")"
TEMP_CONFIG="$TEMP_DIR/wrangler.json"
ATTACHED=0
OBSERVER_DEPLOYED=0

send_canaries() {
    curl --silent --show-error \
        --header "x-harc-relay-capability: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
        --header "x-harc-redaction-1: HARC-REDACTION-CANARY-INVITATION" \
        --header "x-harc-redaction-2: HARC-REDACTION-CANARY-DEVICE-KEY" \
        --header "x-harc-redaction-3: HARC-REDACTION-CANARY-HOST-NAME" \
        --header "x-harc-redaction-4: HARC-REDACTION-CANARY-RECORDING-NAME" \
        --header "x-harc-redaction-5: HARC-REDACTION-CANARY-TRANSCRIPT" \
        --header "x-harc-redaction-6: HARC-REDACTION-CANARY-AUDIO" \
        "$STAGING_ORIGIN/health" >/dev/null
}

cleanup() {
    local original_status="$?"
    local cleanup_status=0
    trap - EXIT INT TERM

    cd "$RELAY_ROOT"
    if [[ "$ATTACHED" == "1" ]]; then
        if WRANGLER_SEND_ERROR_REPORTS=false npx wrangler deploy \
            --env staging \
            --message "Detach temporary Harc redaction observer"; then
            ATTACHED=0
        else
            echo "error: failed to restore staging without the observer; leaving observer deployed" >&2
            cleanup_status=1
        fi
    fi

    if [[ "$ATTACHED" == "0" && "$OBSERVER_DEPLOYED" == "1" ]]; then
        if WRANGLER_SEND_ERROR_REPORTS=false npx wrangler delete \
            "$OBSERVER_NAME" --force; then
            OBSERVER_DEPLOYED=0
        else
            echo "error: failed to delete the temporary observer" >&2
            cleanup_status=1
        fi
    fi

    if [[ "$TEMP_DIR" == "$TEMP_ROOT"/harc-relay-redaction.* ]]; then
        rm -rf -- "$TEMP_DIR"
    else
        echo "error: refusing to remove unexpected temporary path: $TEMP_DIR" >&2
        cleanup_status=1
    fi

    if [[ "$ATTACHED" == "0" ]]; then
        if ! npm run staging:privacy:deployed:check; then
            cleanup_status=1
        fi
        if ! HARC_RELAY_STAGING_ORIGIN="$STAGING_ORIGIN" \
            npm run staging:overload; then
            cleanup_status=1
        fi
    fi

    if [[ "$original_status" != "0" || "$cleanup_status" != "0" ]]; then
        exit 1
    fi
}
trap cleanup EXIT INT TERM

cd "$RELAY_ROOT"
npm run privacy:check
npm run staging:privacy:deployed:check
npm run redaction:observer:types:check
npm run typecheck
npm run test:redaction-observer
npm run redaction:observer:dry

node scripts/generate-redaction-staging-config.mjs "$TEMP_CONFIG"
WRANGLER_SEND_ERROR_REPORTS=false npx wrangler deploy \
    --config "$TEMP_CONFIG" \
    --env staging \
    --dry-run \
    --outdir "$RELAY_ROOT/dist/redaction-exercise"

WRANGLER_SEND_ERROR_REPORTS=false npx wrangler deploy \
    --config wrangler.redaction-observer.jsonc \
    --message "Temporary aggregate-only Harc redaction observer"
OBSERVER_DEPLOYED=1

CONSECUTIVE_HEALTH=0
for _ in {1..120}; do
    if curl --fail --silent "$OBSERVER_ORIGIN/health" >/dev/null; then
        CONSECUTIVE_HEALTH=$((CONSECUTIVE_HEALTH + 1))
        if [[ "$CONSECUTIVE_HEALTH" == "5" ]]; then
            break
        fi
    else
        CONSECUTIVE_HEALTH=0
    fi
    sleep 0.5
done
if [[ "$CONSECUTIVE_HEALTH" != "5" ]]; then
    echo "error: temporary observer did not propagate to five consecutive health checks" >&2
    exit 1
fi

RESET_COMPLETE=0
for _ in {1..120}; do
    if curl --fail --silent --show-error \
        --request POST "$OBSERVER_ORIGIN/reset" >/dev/null; then
        RESET_COMPLETE=1
        break
    fi
    sleep 0.5
done
if [[ "$RESET_COMPLETE" != "1" ]]; then
    echo "error: temporary observer reset endpoint did not become ready" >&2
    exit 1
fi

WRANGLER_SEND_ERROR_REPORTS=false npx wrangler deploy \
    --config "$TEMP_CONFIG" \
    --env staging \
    --message "Attach temporary aggregate-only redaction observer"
ATTACHED=1

HARC_RELAY_WORKER_NAME=harc-remote-relay-staging \
HARC_RELAY_HEALTH_URL="$STAGING_ORIGIN/health" \
HARC_RELAY_AUDIT_LABEL="Staging redaction exercise" \
HARC_RELAY_EXPECTED_TAIL_CONSUMER="$OBSERVER_NAME" \
    bash scripts/check-deployed-privacy.sh

send_canaries

HARC_RELAY_STAGING_ORIGIN="$STAGING_ORIGIN" npm run staging:overload

cd "$PROJECT_ROOT"
HARC_RELAY_EMULATOR_ORIGIN="$STAGING_ORIGIN" \
    swift test --jobs 2 --filter PinnedGRPCLoopbackIntegrationTests
send_canaries

REPORT=""
for _ in {1..120}; do
    REPORT="$(curl --fail --silent --show-error "$OBSERVER_ORIGIN/report")"
    if node -e '
const report = JSON.parse(process.argv[1]);
process.exit(report.canaryHeaderOccurrencesDiscarded >= 6 &&
  report.nonFetchEvents > 0 &&
  report.hostSessionEndpoints > 0 &&
  report.sessionConnectEndpoints > 0 ? 0 : 1);
' "$REPORT"; then
        break
    fi
    sleep 0.5
done

echo "Aggregate-only staging redaction report candidate:"
echo "$REPORT"

node -e '
const report = JSON.parse(process.argv[1]);
const serialized = JSON.stringify(report);
const requiredPositive = [
  "producerEvents",
  "fetchEvents",
  "nonFetchEvents",
  "hostSessionEndpoints",
  "sessionConnectEndpoints",
  "requestHeaderFieldsDiscarded",
  "sensitiveHeaderOccurrencesDiscarded",
  "canaryHeaderOccurrencesDiscarded",
  "cfMetadataObjectsDiscarded",
];
for (const name of requiredPositive) {
  if (!Number.isSafeInteger(report[name]) || report[name] <= 0) {
    throw new Error(`expected positive aggregate ${name}`);
  }
}
if (report.schemaVersion !== 1 || report.canaryHeaderOccurrencesDiscarded < 6 ||
    report.logAndExceptionPlaintextMarkers !== 0 || report.logRecords !== 0 ||
    report.exceptionRecords !== 0 || report.diagnosticRecords !== 0 ||
    report.truncatedEvents !== 0) {
  throw new Error(`unsafe or incomplete aggregate report: ${serialized}`);
}
for (const forbidden of [
  "HARC-REDACTION-CANARY",
  "x-harc-relay-capability",
  "/v1/hosts/",
  "/v1/sessions/",
]) {
  if (serialized.includes(forbidden)) {
    throw new Error("aggregate report retained a forbidden field");
  }
}
console.log("Safe staging redaction report:");
console.log(JSON.stringify(report, null, 2));
' "$REPORT"
