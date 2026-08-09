#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_ROOT="$PROJECT_ROOT/CloudflareRelay"
EXPECTED_ORIGIN="https://harc-remote-relay-staging.jlworker.workers.dev"
RELAY_ORIGIN="${HARC_RELAY_STAGING_ORIGIN:-$EXPECTED_ORIGIN}"

cleanup() {
    local original_status="$?"
    local cleanup_status=0
    trap - EXIT INT TERM

    cd "$RELAY_ROOT"
    if ! npm run staging:privacy:deployed:check; then
        cleanup_status=1
    fi

    if [[ "$original_status" != "0" || "$cleanup_status" != "0" ]]; then
        exit 1
    fi
}

if [[ "$RELAY_ORIGIN" != "$EXPECTED_ORIGIN" ]]; then
    echo "error: refusing non-qualified staging origin: $RELAY_ORIGIN" >&2
    exit 1
fi
trap cleanup EXIT INT TERM

cd "$RELAY_ROOT"
npm run staging:privacy:deployed:check
HARC_RELAY_STAGING_ORIGIN="$RELAY_ORIGIN" npm run staging:lifecycle
