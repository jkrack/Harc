# HarcMobile App Privacy assessment

**Prepared:** 2026-08-09
**Decision owner:** App Store Connect Account Holder

## Current finding

The target production source configuration now disables persistent Cloudflare
Workers Logs and Traces and exports no request telemetry. This aligns with
Harc's no-external-telemetry product rule and the app privacy manifest's empty
`NSPrivacyCollectedDataTypes` array.

Production Worker version `6aee297a-49ea-4f92-8dab-3bdad4037976` is active at
100%. On 2026-08-09 at 15:12 UTC, the script-settings API returned Logpush
disabled, no Tail Workers, and `observability: null` after the reviewed
settings-only privacy change; the live health endpoint remained HTTP 200.
At 15:18 UTC, the authenticated Cloudflare Observability dashboard returned
zero Workers events and zero traces for `scriptName = "harc-remote-relay"` over
the preceding hour. The query ran more than two minutes after the post-change
health requests, covering Cloudflare's stated dashboard ingestion delay.

This closes the deployed-configuration mismatch. **No, we do not collect data
from this app** still requires the remaining operator checks below, expiration
of records retained by the superseded sampled configuration, and Account Holder
confirmation for the exact uploaded build.

Apple defines collection as readable data retained longer than necessary to
service the transmitted request. Apple specifically says an IP address sent on
a server call and not retained does not need to be disclosed. If an IP address
is stored, Apple directs developers to disclose the types implied by its use,
such as coarse location, device ID, or diagnostics.

## Exact-deployment evidence required

- **Passed:** production read-back shows Logpush disabled, no Tail Workers, and
  observability absent/disabled on the single version receiving 100% of traffic.
  The source config additionally fixes logs, invocation logs, traces, Logpush,
  Tail Workers, and streaming Tail Workers off/empty.
- **Passed:** the deployed version ID and settings inspection are reproducible
  with `npm run privacy:deployed:check`; the command also verifies `/health`.
- **Passed for the post-change health interval:** authenticated dashboard
  queries returned zero Workers events and zero traces for
  `harc-remote-relay`.
- **Passed for the complete synthetic staging interval:** Host registration,
  session admission, overload close, a 1,000-Host hold, and active transfer ran
  with persistent observability disabled; after the ingestion delay, staging
  dashboard queries returned zero retained Worker events and zero traces.
- **Passed for the deployed Worker and account export surfaces:** script settings have no logs or
  trace destinations, Logpush or Tail Worker; the deployed bundle has only the
  two Durable Object and rate-limit bindings, with no Analytics Engine, R2, D1,
  or other request-log binding. The authenticated Account Holder dashboard
  additionally showed **No Logpush jobs** under Account-scoped Logpush.
- **Passed in the Account Holder dashboard; executable API check prepared:**
  `npm run privacy:account-logpush:check` uses the account Logpush job-list API
  without printing destinations or filters and fails if any
  `workers_trace_events` export exists. The current Wrangler OAuth token lacks
  the separate Logs permission, so the dashboard supplied this run's evidence.
- **Passed:** a purpose-built aggregate-only observer discarded 261 header
  fields, 28 secret-header occurrences, six named canaries, and 11 Cloudflare
  metadata objects across 85 complete-flow events. It persisted no raw values,
  logs, exceptions, or diagnostics, then was detached and deleted. Raw
  Cloudflare real-time tailing remains prohibited.
- **Passed:** the account is on Workers Paid and the staging resource/cost
  dashboard was recorded. Remaining service metrics exposed aggregate counts
  and percentiles rather than request headers, route IDs, IP-derived location,
  user agents, or content.
- Confirm that any records created by the superseded private-beta configuration
  have expired. Cloudflare documents seven-day Workers Logs/Traces retention on
  the Paid plan; records last created on 2026-08-09 must be absent by
  2026-08-16 before the privacy answer is frozen.
- **Passed locally and through real staging application transport:** the
  negative relay-frame inspection found no invitation,
  credential, path, recording name, transcript, audio, or inner application
  plaintext; the pinned TLS bootstrap, Library, reconciliation, and resume flow
  then passed through the deployed staging Worker, including during the bounded
  safe-redaction exercise.

## App Store Connect answer branches

| Exact production behavior | App Privacy answer |
| --- | --- |
| No readable per-request data retained beyond real-time service; no exports | **No data collected** is supportable, subject to Account Holder confirmation |
| Sampled logs/traces or another per-request destination enabled | **Yes**; disclose every retained type and update the manifest/policy before service |
| Behavior or retention cannot be verified | **Stop submission**; do not guess |

If retention is enabled, the conservative assessment must consider at least
Coarse Location, Other Usage Data, and Other Diagnostic Data for App
Functionality, with no tracking. Whether each type is linked to the user depends
on the exact fields and whether IP, device-level, route, or other identifying
data remains joinable. Audio Data is not a relay collection type when the relay
receives only inner-TLS ciphertext and cannot decrypt it.

## Privacy manifest consistency

The shipped `PrivacyInfo.xcprivacy`, App Store Connect answer, in-app Privacy &
Data copy, public privacy policy, and deployed relay must describe the same
release behavior. Any production change that enables persistent request
observability requires all five surfaces to be reviewed before deployment.

## Primary references

- [Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
- [Cloudflare Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/)
- [Cloudflare Workers Traces](https://developers.cloudflare.com/workers/observability/traces/)
- [Cloudflare trace fields](https://developers.cloudflare.com/workers/observability/traces/spans-and-attributes/)
