#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_ROOT="$PROJECT_ROOT/CloudflareRelay"
RELAY_PORT="${HARC_RELAY_EMULATOR_PORT:-8799}"
RELAY_ORIGIN="http://127.0.0.1:$RELAY_PORT"
RELAY_STATE="$(mktemp -d "${TMPDIR:-/tmp}/harc-pairing-relay-state.XXXXXX")"
RELAY_LOG="$(mktemp "${TMPDIR:-/tmp}/harc-pairing-relay-log.XXXXXX")"
RUN_MARKER="/tmp/harc-run-pairing-lifecycle-e2e-$UID"
RELAY_PID=""

cleanup() {
    rm -f -- "$RUN_MARKER"
    if [[ -n "$RELAY_PID" ]]; then
        kill "$RELAY_PID" 2>/dev/null || true
        wait "$RELAY_PID" 2>/dev/null || true
    fi
    rm -rf -- "$RELAY_STATE"
    rm -f -- "$RELAY_LOG"
}
trap cleanup EXIT INT TERM

minimum_free_kib=$((5 * 1024 * 1024))
available_free_kib=$(df -Pk "$PROJECT_ROOT" | awk 'NR == 2 { print $4 }')
if [[ -z "$available_free_kib" || "$available_free_kib" -lt "$minimum_free_kib" ]]; then
    echo "Relay pairing lifecycle stopped: Harc requires at least 5 GiB free." >&2
    exit 1
fi

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

touch "$RUN_MARKER"
cd "$PROJECT_ROOT"
swift_test_options=(--jobs 2)
if [[ "${HARC_SKIP_BUILD:-0}" == "1" ]]; then
    swift_test_options+=(--skip-build)
fi
HARC_RELAY_EMULATOR_ORIGIN="$RELAY_ORIGIN" \
    swift test "${swift_test_options[@]}" \
        --filter PairingLifecycleLoopbackIntegrationTests
