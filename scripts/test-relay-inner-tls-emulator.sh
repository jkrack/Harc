#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_ROOT="$PROJECT_ROOT/CloudflareRelay"
RELAY_PORT="${HARC_RELAY_EMULATOR_PORT:-8799}"
RELAY_ORIGIN="http://127.0.0.1:$RELAY_PORT"
RELAY_STATE="$(mktemp -d "${TMPDIR:-/tmp}/harc-relay-state.XXXXXX")"
RELAY_LOG="$(mktemp "${TMPDIR:-/tmp}/harc-relay-log.XXXXXX")"
RELAY_PID=""

cleanup() {
    if [[ -n "$RELAY_PID" ]]; then
        kill "$RELAY_PID" 2>/dev/null || true
        wait "$RELAY_PID" 2>/dev/null || true
    fi
    rm -rf "$RELAY_STATE"
    rm -f "$RELAY_LOG"
}
trap cleanup EXIT INT TERM

cd "$RELAY_ROOT"
npx wrangler dev \
    --local \
    --ip 127.0.0.1 \
    --port "$RELAY_PORT" \
    --persist-to "$RELAY_STATE" \
    --log-level warn >"$RELAY_LOG" 2>&1 &
RELAY_PID=$!

for _ in {1..40}; do
    if curl --fail --silent "$RELAY_ORIGIN/health" >/dev/null; then
        break
    fi
    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
        sed -n '1,200p' "$RELAY_LOG" >&2
        exit 1
    fi
    sleep 0.25
done

if ! curl --fail --silent "$RELAY_ORIGIN/health" >/dev/null; then
    sed -n '1,200p' "$RELAY_LOG" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
HARC_RELAY_EMULATOR_ORIGIN="$RELAY_ORIGIN" \
    swift test --jobs 2 --filter PinnedGRPCLoopbackIntegrationTests
