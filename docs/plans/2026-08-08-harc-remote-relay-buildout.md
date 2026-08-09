# Harc Remote Relay Buildout

**Status:** Production relay and hardened Worker deployed; opt-in Harc 0.14.0
release candidate notarized, with expanded load, cost, and two-network evidence
continuing as post-release operations

**Date:** 2026-08-08

**Architecture:** [Harc Remote relay architecture](../architecture/harc-remote-relay.md)

**Normative specification:** [Harc Remote relay specification](../specs/2026-08-08-harc-remote-relay-spec.md)

## Objective

Add integrated remote reachability for one authoritative Harc Host and N adopted
clients without exposing content plaintext to Cloudflare or destabilizing direct
LAN, standalone capture, local client processing, or durable transfer recovery.

## Ordered slices

## 2026-08-08 implementation checkpoint

- `CloudflareRelay` has current generated bindings, a hibernatable Host
  rendezvous, isolated two-peer session objects, hashed capability admission,
  replay/role bounds, a 1 MiB frame limit, 120-second payload-idle expiry, and
  a 24-hour absolute deadline, a 32-route Host cap, edge admission limiting,
  and a durable three-request/one-per-second per-device token bucket.
  Local hardening now uses the runtime timing-safe primitive and atomically
  reserves one-time pairing and role capabilities before external awaits.
  `npm run check` passes 12 tests and a Wrangler dry run. Worker version
  `3a48546b-15b7-49b9-8b11-22c8a2dea624` is deployed at
  `https://relay.adaptcontext.com`; the additional `workers.dev` route is
  disabled. The local hardening changes postdate that deployed version and must
  pass staging verification before an approved redeployment.
- A live throwaway-capability smoke test passed session admission, Host and
  client role readiness, byte-for-byte random binary forwarding, and the
  acknowledgement path through the deployed Durable Objects.
- Both app targets receive `https://relay.adaptcontext.com` through the
  generated `HarcRemoteRelayOrigin` Info.plist setting. Harc Remote remains
  default-off and direct LAN remains preferred.
- The Swift package has a neutral `HarcRemoteTransport` target shared by the
  sibling Host and Client adapters, a default-off relay policy, Host control
  agent, direct
  first/client relay fallback, loopback byte pumps around the existing pinned
  TLS gRPC channel, compact relay pairing endpoints, and Host lifecycle wiring.
- Focused Swift relay and pairing-ticket tests pass. The complete bounded Swift
  regression passes 1,540 tests in 259 suites, the macOS Harc Debug app target
  builds with both production helpers embedded, and the generic-device iOS
  HarcMobile Debug target builds with signing disabled.
- The relay-enabled `0.14.0 (55)` macOS release candidate builds arm64-only,
  carries `https://relay.adaptcontext.com` in its packaged Info.plist, is signed
  with Developer ID, notarized and stapled, and passes the release verifier and
  Gatekeeper. GitHub/Sparkle publication remains a separate release action.
- The first macOS attempt was stopped when Xcode crossed the agreed 10 GiB
  safety floor. Clearing only npm's rebuildable download cache restored enough
  headroom; the completed validations stayed above the 10 GiB stop line and
  ended with approximately 12 GiB free.
- Approval now replaces the one-time invitation bearer with a newly generated
  per-device route/capability delivered over the already pinned and
  claim-authenticated pairing channel. The Host retains only a ten-minute
  this-device-only Keychain delivery envelope; desktop and iOS persist only the
  replacement route.
- A Remote invitation derives its 24-byte pairing admission bearer from the
  complete canonical ticket. The Host reservation stores only the binding of
  that value, and the existing client proof and SAS cover the binding. Relay
  endpoint addition, removal, or modification therefore fails admission while
  direct-only tickets retain their frozen V1 behavior.
- Relay byte pumps use one 1 MiB frame credit in each direction and forward an
  acknowledgement only after the receiving loopback socket accepts the frame,
  preventing unbounded application queues.
- General settings expose the default-off Harc Remote Host control and live
  connection state. Paired-device management persists a device-to-relay-route
  binding in this-device-only Keychain storage, and revocation invalidates the
  authoritative Harc grant before removing the relay admission. An
  already-revoked device can retry remote cleanup after a transient failure.
- Host-rendezvous eviction, concurrent capability replay, rate-limit, and
  payload-not-persisted tests are green. The Swift bridge and Worker now each
  own one-frame credit state, and the Worker's normal credit lifecycle is
  covered locally. Its forced-close overload branch still requires staging
  evidence because the local hibernation emulator is unstable on that path.
  Relay-session live-socket eviction,
  local-emulator inner-TLS, wire plaintext-negative, two-network physical-device,
  1,000-idle-Host, pricing, physical-device iOS, and expanded two-network
  evidence remain post-release follow-up work.

### R0 — Contract and local relay skeleton

- Ratify the privacy boundary, one-Host/N-client topology, capability model,
  quotas, Host minimum, deployment gates, and cost measurements.
- Add an isolated `CloudflareRelay` TypeScript project with current Wrangler,
  generated binding types, SQLite Durable Object migrations, hibernatable
  WebSockets, strict bounds, and local Vitest coverage.
- Do not deploy or add production secrets.

Exit: configuration validates, types are generated, tests pass locally, and a
dry-run bundle is inspectable without touching a Cloudflare account.

### R1 — Relay control plane

- Implement Host rendezvous registration using an opaque route and hashed Host
  capability.
- Add Host-authorized pairing and device relay capability installation,
  one-time session issuance, expiry, replay protection, and revocation.
- Keep payload logging and secret-header logging disabled.
- Keep persistent logs and traces disabled in the production configuration;
  use only a distinct, time-bounded staging exercise for redaction evidence.

Exit: capability and lifecycle tests pass across Durable Object eviction, and a
third peer or replay cannot enter a session.

### R2 — Blind session data plane

- Implement exactly-two-peer binary forwarding with role attachments.
- Enforce frame, idle, lifetime, queue, and close-code limits.
- Add byte-for-byte, backpressure, disconnect, eviction, and resumed-session
  tests.

The Worker now persists one outstanding-frame bit in each hibernatable socket
attachment, clears it only when the opposite peer acknowledges delivery, and
closes both peers with `4429 receiver_overloaded` if a sender exceeds its
credit. Local coverage proves the normal credit lifecycle; record the forced-
close branch in staging before claiming the overload exit.

Exit: random binary fixtures traverse unchanged and no content is persisted.

### R3 — Swift tunnel bridge

- Add a transport-neutral relay route to the adopted Host state.
- Implement client and Host loopback bridges around the existing inner
  pinned-TLS gRPC connection.
- Prefer direct LAN and fall back to relay without changing the durable outbox.
- Gate all behavior behind an internal Harc Remote feature flag.

Exit: one signed library RPC and one resumable upload pass through the local
Worker emulator; a wire-inspection test finds no known application plaintext;
direct behavior remains unchanged. **Passed 2026-08-08:**
`./scripts/test-relay-inner-tls-emulator.sh` starts a fresh `wrangler dev`
process and carries the real pinned TLS 1.3 channel through it. The test passes
an authenticated Library snapshot, reconciles one durable upload chunk, resumes
the second chunk, and rejects known Host-name, gRPC-path, session-credential,
and audio plaintext from every captured relay-visible binary frame. The same
test also passes directly when the emulator environment is absent.

### R4 — Pairing and device UX

- Extend the `.harcpair` ticket with an optional expiring relay route and bind
  its canonical bytes into an authenticated pairing transcript or new signed
  envelope.
- Add explicit remote-sharing disclosure, import, SAS, Host approval, paired
  device identity, last-route state, and revocation UI.
- Keep one remembered Host per client and N device grants on the Host.

Exit: a secondary Mac can receive a `.harcpair` file through a user-selected
channel, pair remotely, appear by identity on the Host, and lose access after
revocation. **Open:** real secondary-Mac evidence.

### R5 — Private staging deployment

- The Cloudflare account, `harc-remote-relay` Worker, and
  `relay.adaptcontext.com` service hostname are selected explicitly.
- No operator-managed application secret is required; Harc generates opaque
  route capabilities on-device and the relay persists only their hashes.
- Deploy a distinct staging environment with time-bounded sampling, verify log
  redaction and deletion, and run two-network iPhone and Mac tests. Confirm the
  production deployment has persistent Workers Logs and Traces disabled.

Exit: physical-device evidence covers unavailable Host, network changes,
interrupted transfer, direct-route recovery, and no content in observability.

### R6 — Load, pricing, and release

- Simulate at least 1,000 idle Host rendezvous connections plus representative
  active ALAC transfer.
- Record message, duration, CPU, memory, and operational support cost.
- Approve per-Host pricing, included remote allowance, abuse limits, and support
  policy before production deployment.
- Complete bounded Swift tests, macOS app build, iOS build, notarization, Sparkle
  publication, and staged remote enablement.

Exit: production is opt-in, reversible, measured, and does not make capture or
LAN use depend on the relay.

## Machine-safe validation

On the current 16 GB development Mac, use at most two Swift/Xcode workers. Keep
Node and Swift validation focused, preserve useful warm build artifacts, and
stop before free disk falls below 5 GiB. Cloudflare relay tests run independently
of the full Swift suite until the Swift bridge lands.

## Deployment boundary

Cloudflare account mutations require an explicit target account and hostname.
The production deployment was approved on 2026-08-09 for
`relay.adaptcontext.com`; hardened Worker version
`6aee297a-49ea-4f92-8dab-3bdad4037976` is deployed there. No coding step may
silently create another public endpoint.
