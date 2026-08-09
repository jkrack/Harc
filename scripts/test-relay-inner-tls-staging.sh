#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_ROOT="$PROJECT_ROOT/CloudflareRelay"
EXPECTED_ORIGIN="https://harc-remote-relay-staging.jlworker.workers.dev"
RELAY_ORIGIN="${HARC_RELAY_STAGING_ORIGIN:-$EXPECTED_ORIGIN}"

if [[ "$RELAY_ORIGIN" != "$EXPECTED_ORIGIN" ]]; then
    echo "error: refusing non-qualified staging origin: $RELAY_ORIGIN" >&2
    exit 1
fi

cd "$RELAY_ROOT"
npm run staging:privacy:deployed:check

if ! curl --fail --silent --show-error "$RELAY_ORIGIN/health" >/dev/null; then
    echo "error: staging relay health check failed" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
HARC_RELAY_EMULATOR_ORIGIN="$RELAY_ORIGIN" \
    swift test --jobs 2 --filter PinnedGRPCLoopbackIntegrationTests

cd "$RELAY_ROOT"
npm run staging:privacy:deployed:check
