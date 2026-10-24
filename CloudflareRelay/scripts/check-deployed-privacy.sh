#!/usr/bin/env bash
set +x # Never trace credential expansion, including when invoked with bash -x.
set -euo pipefail

# Read-only proof that an active relay deployment has no persistent request
# observability attached. This is deliberately separate from `npm run check`,
# because it requires Cloudflare credentials and network access.

WORKER_NAME="${HARC_RELAY_WORKER_NAME:-harc-remote-relay}"
AUDIT_LABEL="${HARC_RELAY_AUDIT_LABEL:-Production}"
ACCOUNT_ID="${HARC_CLOUDFLARE_ACCOUNT_ID:-676fddd7d11dccf4ed698060965271c7}"
WRANGLER_PROFILE_PATH="${HARC_WRANGLER_PROFILE_PATH:-$HOME/.wrangler/config/default.toml}"
API_ORIGIN="https://api.cloudflare.com/client/v4"
RELAY_HEALTH_URL="${HARC_RELAY_HEALTH_URL:-https://relay.adaptcontext.com/health}"
EXPECTED_TAIL_CONSUMER="${HARC_RELAY_EXPECTED_TAIL_CONSUMER:-}"

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_JSON="$(node "$SCRIPT_DIRECTORY/read-deployment-status.mjs" "$WORKER_NAME")"

if [[ -n "${HARC_CLOUDFLARE_API_TOKEN:-}" ]]; then
  HARC_RELAY_AUDIT_TOKEN="$HARC_CLOUDFLARE_API_TOKEN"
elif [[ -f "$WRANGLER_PROFILE_PATH" ]]; then
  HARC_RELAY_AUDIT_TOKEN="$(awk '
    /^oauth_token[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*"/, "")
      sub(/"[[:space:]]*$/, "")
      print
      exit
    }
  ' "$WRANGLER_PROFILE_PATH")"
else
  echo "error: no Harc Cloudflare API token or Wrangler profile is available" >&2
  exit 1
fi
trap 'unset HARC_RELAY_AUDIT_TOKEN' EXIT

if [[ "$HARC_RELAY_AUDIT_TOKEN" == *$'\n'* || "$HARC_RELAY_AUDIT_TOKEN" == *$'\r'* ]]; then
  echo "error: invalid multiline Cloudflare token" >&2
  exit 1
fi

if [[ -z "$HARC_RELAY_AUDIT_TOKEN" ]]; then
  echo "error: the Harc Cloudflare API token is empty" >&2
  exit 1
fi

if ! SETTINGS_JSON="$(curl --disable \
  --connect-timeout 5 \
  --max-time 20 \
  --silent \
  --show-error \
  --fail \
  --header @- \
  "$API_ORIGIN/accounts/$ACCOUNT_ID/workers/scripts/$WORKER_NAME/script-settings" \
  <<< "Authorization: Bearer $HARC_RELAY_AUDIT_TOKEN"
)"; then
  echo "error: relay settings request failed (5-second connect, 20-second total deadline)" >&2
  exit 1
fi

VERSION_ID="$(node -e '
const payload = JSON.parse(process.argv[1]);
const versions = payload.versions;
if (!Array.isArray(versions) || versions.length !== 1 || versions[0].percentage !== 100) {
  throw new Error("relay must have exactly one Worker version at 100 percent");
}
process.stdout.write(versions[0].version_id);
' "$DEPLOYMENT_JSON")"

node -e '
const payload = JSON.parse(process.argv[1]);
const expectedTailConsumer = process.argv[2];
if (payload.success !== true || payload.result === null) {
  throw new Error("Cloudflare did not return relay script settings");
}
const settings = payload.result;
if (settings.logpush !== false) {
  throw new Error(`Logpush must be false; found ${JSON.stringify(settings.logpush)}`);
}
const tailConsumers = settings.tail_consumers ?? [];
if (!Array.isArray(tailConsumers)) {
  throw new Error("relay Tail Workers setting must be an array or null");
}
const services = tailConsumers.map((consumer) =>
  typeof consumer === "string" ? consumer : consumer?.service);
if (expectedTailConsumer === "") {
  if (services.length !== 0) {
    throw new Error("relay must have no Tail Workers");
  }
} else if (services.length !== 1 || services[0] !== expectedTailConsumer) {
  throw new Error("relay must have exactly the named temporary Tail Worker");
}
// Do not interpret an omitted field as proof that no streaming observer exists.
if (!Object.hasOwn(settings, "streaming_tail_consumers")) {
  throw new Error("streaming Tail Workers were not reported; deployed privacy remains unverified");
}
const streamingConsumers = settings.streaming_tail_consumers;
if (streamingConsumers !== null && (!Array.isArray(streamingConsumers) || streamingConsumers.length !== 0)) {
  throw new Error("relay must have no streaming Tail Workers");
}
const observability = settings.observability;
if (observability !== null && observability !== undefined) {
  if (observability.enabled !== false) {
    throw new Error("relay observability must be disabled");
  }
  for (const [name, channel] of [
    ["logs", observability.logs],
    ["traces", observability.traces],
  ]) {
    if (channel === null || channel === undefined) continue;
    if (channel.enabled !== false || channel.persist === true) {
      throw new Error(`relay ${name} must be disabled and non-persistent`);
    }
    if (Array.isArray(channel.destinations) && channel.destinations.length !== 0) {
      throw new Error(`relay ${name} must have no export destinations`);
    }
  }
}
' "$SETTINGS_JSON" "$EXPECTED_TAIL_CONSUMER"

if ! HEALTH_BODY="$(curl --disable --connect-timeout 5 --max-time 20 --silent --show-error --fail "$RELAY_HEALTH_URL")"; then
  echo "error: relay health request failed (5-second connect, 20-second total deadline)" >&2
  exit 1
fi
if [[ "$HEALTH_BODY" != '{"status":"ok"}' ]]; then
  echo "error: unexpected relay health response: $HEALTH_BODY" >&2
  exit 1
fi

echo "$AUDIT_LABEL relay privacy check passed."
echo "  Worker:        $WORKER_NAME"
echo "  Version:       $VERSION_ID (100%)"
echo "  Logpush:       disabled"
if [[ -z "$EXPECTED_TAIL_CONSUMER" ]]; then
  echo "  Tail Workers:  none"
else
  echo "  Tail Workers:  $EXPECTED_TAIL_CONSUMER (temporary expected observer)"
fi
echo "  Streaming Tail Workers: none"
echo "  Observability: disabled"
echo "  Health:        ok"
echo "  Checked UTC:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
