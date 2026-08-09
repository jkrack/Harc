# Cloudflare account Logpush evidence

**Date:** 2026-08-09
**Scope:** account-level export destinations for Harc relay invocation records

## Result

**Pass.** The authenticated Cloudflare dashboard's **Logpush > Jobs** page
showed **No Logpush jobs** under **Account-scoped Logpush**. Therefore no
current account-level `workers_trace_events` Logpush job exports relay
invocation records to a separate destination.

The repository now includes the read-only
`npm run privacy:account-logpush:check` audit. It calls Cloudflare's account
Logpush job-list API, prints counts only, and fails if any Workers Trace Events
job exists. The current Wrangler OAuth token receives HTTP 403 because it lacks
the API's separate Logs permission, so the Account Holder's authenticated
dashboard supplied the evidence for this run. No job destination, filter,
credential, or other operator configuration was printed or captured.

## Boundary

This proves current account-level Logpush configuration. It does not accelerate
expiry of records written by the superseded sampled Workers Logs/Traces
configuration. Records last written on 2026-08-09 must still be confirmed absent
after the documented seven-day retention window on 2026-08-16. It also does not
replace the Account Holder's exact-build App Privacy confirmation in App Store
Connect.
