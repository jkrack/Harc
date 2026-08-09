#!/usr/bin/env bash
set -euo pipefail

# Read-only account-level proof that no Workers Trace Events Logpush job can
# export relay invocation records. Deliberately prints counts only: Logpush
# destinations and filters can contain sensitive operator configuration.

ACCOUNT_ID="${HARC_CLOUDFLARE_ACCOUNT_ID:-676fddd7d11dccf4ed698060965271c7}"
WRANGLER_PROFILE_PATH="${HARC_WRANGLER_PROFILE_PATH:-$HOME/.wrangler/config/default.toml}"
API_ORIGIN="https://api.cloudflare.com/client/v4"

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

if [[ -z "$HARC_RELAY_AUDIT_TOKEN" ]]; then
  echo "error: the Harc Cloudflare API token is empty" >&2
  exit 1
fi

curl \
  --silent \
  --show-error \
  --fail \
  --header "Authorization: Bearer $HARC_RELAY_AUDIT_TOKEN" \
  "$API_ORIGIN/accounts/$ACCOUNT_ID/logpush/jobs" \
  | node -e '
const chunks = [];
process.stdin.on("data", (chunk) => chunks.push(chunk));
process.stdin.on("end", () => {
  const raw = Buffer.concat(chunks).toString("utf8");
  if (raw.trim() === "") {
    console.error(
      "error: Cloudflare account Logpush jobs were not readable; use a " +
        "token with account Logs access or verify them in the dashboard"
    );
    return;
  }
  const payload = JSON.parse(raw);
  if (payload.success !== true || !Array.isArray(payload.result)) {
    throw new Error("Cloudflare did not return the account Logpush job list");
  }

  const jobs = payload.result;
  const workerJobs = jobs.filter(
    (job) => job?.dataset === "workers_trace_events"
  );
  const enabledWorkerJobs = workerJobs.filter(
    (job) => job?.enabled === true
  );

  console.log("Cloudflare account Logpush audit completed.");
  console.log(`  Account jobs:             ${jobs.length}`);
  console.log(`  Workers Trace Event jobs: ${workerJobs.length}`);
  console.log(`  Enabled Worker jobs:      ${enabledWorkerJobs.length}`);

  if (workerJobs.length !== 0) {
    throw new Error(
      "Workers Trace Event Logpush jobs exist; inspect their destination " +
        "retention before freezing the App Privacy answer"
    );
  }
});
'

echo "  Result:                   no account-level Workers export"
echo "  Checked UTC:              $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
