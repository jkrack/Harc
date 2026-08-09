# Harc project, specification, and architecture audit

**Date:** 2026-08-08

**Reviewed source:** `main` at `7b96343` plus the active Harc Remote, pairing,
mobile-codec, and privacy worktree for 0.13.9 (54)

**Primary contract:**
[Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

**Remote extension contract:**
[Harc Remote relay specification](../specs/2026-08-08-harc-remote-relay-spec.md)

## Decision

**Harden the current design; do not redesign it.**

The standalone Mac app and the implemented Host/client/mobile core use the
right architectural shape: the resident Mac Host remains authoritative,
capture is durable before derived work, clients retain recoverable source
audio, authenticated domain objects cross the wire instead of local database
records, and a durable audio-safety receipt precedes processing. The relay is
correctly modeled as an optional untrusted transport around the existing
pinned-TLS application channel rather than as a new Host or content service.

## Release decision update — 2026-08-09

The product owner accepted Harc Remote for production release as an opt-in
feature. Hardened Worker version `6aee297a-49ea-4f92-8dab-3bdad4037976` is live
at `relay.adaptcontext.com`, and the signed, notarized, stapled Harc 0.14.0 (55)
candidate carries that origin. This supersedes this audit's earlier Harc Remote
no-go conclusion. Expanded load, pricing, privacy-observability, and unrelated-
network scenarios remain post-release operational evidence; iPhone App Store
distribution remains a separate decision.

## Specification trace

| Surface | Finding | Evidence or remaining gate |
| --- | --- | --- |
| Private, local-first inference | Conforms | Standalone capture, storage, STT, and summarization remain local. Adopted-Host processing is explicit. Optional relay forwards encrypted bytes and is not a processor or backup. |
| Menu-bar and long-form reliability | Conforms | Existing macOS capture and recovery architecture remains authoritative; no reviewed change makes optional Host, mobile, or relay availability a capture prerequisite. |
| Domain and wire boundary | Conforms | `HarcDomain`, `HarcIdentity`, generated `HarcProtocolWire`, and validated `HarcProtocol` remain separated. The schema guard rejects filesystem/database identifiers and passed in this audit. |
| Host authority and durable publication | Conforms in source | Canonical ingest, publication journal, receipts, and recovery remain Host-owned. Audio safety is acknowledged before derived processing. |
| Pairing and session security | Conforms for direct transport | Device proof, pinned TLS, short-lived/single-use pairing, human comparison, foreground Host approval, signed objects, and scoped capabilities remain layered rather than collapsed into transport security. |
| iPhone capture and transfer | Source-complete; physical diagnostics started | Protected master, persistent outbox, immutable batches, background-task reconciliation, verified receipt, local playback, and explicit export are implemented. A signed build and all 21 non-UI app tests passed on Omega (`iPhone16,2`, iOS 26.6), but required physical C/T/P/H scenarios have not passed. |
| Mobile lossless codec | Correctly fail-closed | Production selection still requires `HARC_MOBILE_QUALIFIED_CAF_ALAC`. The only full CAF+ALAC hardware run was bit-exact but failed the frozen thermal rule; the four-cell matrix is incomplete. |
| Mobile Library | Conforms in source | Snapshot/delta cache, playback, mutations, conflicts, and speaker identities preserve Host canonical ownership. Physical useful-beta and accessibility evidence remains open. |
| Secondary Mac Client | Conforms in source | Local processing, signed provenance, independent local ownership, Host arbitration, and managed cache policy match the spec. A real second-Mac acceptance run remains open. |
| `harc-mcp` | Conforms | Host-mode authority remains authenticated local IPC with no reviewed direct-database fallback. |
| Harc Remote relay | Accepted for production release | The relay is optional, content-blind, user-enabled, and below inner pinned TLS. Remote invitation bytes are committed into the pairing admission bearer and covered by the existing proof/SAS binding. The Worker independently enforces one outstanding frame per direction. Hardened Worker version `6aee297a-49ea-4f92-8dab-3bdad4037976` is deployed. |
| Privacy and release truth | Production relay aligned; App Store work remains separate | User-facing and policy copy distinguishes standalone-local operation, adopted-Host sync, and optional relay metadata. Production Worker logs and traces are disabled to match the no-external-telemetry contract. Exact-build iOS App Privacy answers and support-page requirements remain App Store gates, not macOS relay-release gates. |

## Architecture corrections made during this audit

1. **Removed a reversed transport dependency.** Relay primitives now live in a
   neutral `HarcRemoteTransport` target used by sibling `HarcHostTransport` and
   `HarcClientTransport` adapters. The Host no longer depends on the Client
   target merely to reuse relay framing and lifetime contracts.
2. **Made one-time relay admission atomic.** The Worker now reserves pairing
   and role capabilities in synchronous Durable Object SQLite critical
   sections before any external or cryptographic await can admit a concurrent
   replay. Failed session initialization restores only the consumed pairing
   authorization without overwriting newer state.
3. **Used the runtime timing-safe comparison.** Capability-digest comparison
   now uses `crypto.subtle.timingSafeEqual` after an explicit length check.
4. **Authenticated the complete Remote invitation.** A Remote ticket now
   derives its pairing admission bearer from the complete canonical ticket.
   The Host stores only that bearer's binding, which the existing client proof
   and SAS already cover. Endpoint addition, removal, or modification therefore
   fails against the original Host reservation; direct-only tickets retain
   their frozen V1 behavior.
5. **Corrected privacy promises.** Welcome, settings, capture, review-sample,
   policy, and release text no longer imply that every adopted-Host or relay
   path remains entirely on the current device or never involves an
   infrastructure provider.
6. **Bounded relay pressure independently of clients.** Each hibernatable
   Worker socket attachment now records whether its last binary frame is still
   awaiting the receiver's acknowledgement. A second frame closes both peers
   with the explicit overload code instead of relying on a well-behaved Swift
   bridge.
7. **Kept the mobile privacy regression aligned with the reviewed promise.**
   The physical app test exposed an expectation for the superseded generic
   no-collection sentence. The test now asserts the narrower, truthful promise:
   no tracking, advertising, analytics, or developer access to recording
   content.
8. **Closed the local relay inner-TLS evidence gap.** A fresh local Worker now
   forwards the production pinned TLS 1.3 gRPC channel for bootstrap and an
   authenticated Library snapshot. The same tunnel carries a declared upload,
   reconciles one durable chunk, resumes the second chunk, and reconciles both.
   Captured relay-visible frames contain none of the known Host-name, gRPC-path,
   session-credential, or audio plaintext fixtures.

## Remaining release blockers

### Mobile and direct Host/client

- Make a clean evidence commit before starting the three-hour codec cells. The
  current physical checks used a dirty worktree and are diagnostic only; a
  report from that tree cannot satisfy the sealed-commit qualification rule.
- Keep Omega (`iPhone16,2`, iOS 26.6) connected and connect the named
  oldest-supported iPhone. Omega was the only physical iPhone visible to Xcode
  during this audit.
- Run the required C1-C7, T1-T7/T2b-T2e, P1, and H1 scenarios on the named
  physical iPhones, including three successful repetitions where the contract
  requires them.
- Repeat all four physical codec cells (oldest/current supported iPhone times
  CAF+ALAC/FLAC) from fresh app processes. Do not enable a shipping codec unless
  the frozen integrity, thermal, latency, memory, and background thresholds
  pass.
- Complete the PR 9 flow on a real secondary Mac: pair, record and transcribe
  locally, upload concurrently, and observe Host acceptance or visible
  reprocessing without merging local libraries.
- Complete physical consent/indicator, Data Protection, backup exclusion,
  VoiceOver, Dynamic Type, interrupted transfer, upgrade/recovery, and exact
  App Store archive checks.

### Harc Remote

- Record the Worker's `4429 receiver_overloaded` forced-close path as expanded
  production regression evidence.
  The source now independently applies one-frame credit, while the local
  hibernation emulator remains unreliable when the test deliberately closes
  live sockets from the message handler.
- Atomic-admission, timing-safe-comparison, and disabled-persistent-observability
  hardening is deployed as Worker version
  `6aee297a-49ea-4f92-8dab-3bdad4037976`.
- Run two-network iPhone and Mac scenarios, eviction/reconnect/revocation
  cases, observability redaction checks, and the 1,000-idle-Host load/pricing
  exercise as post-release operational evidence.
- Keep persistent Workers Logs, Traces, and per-request exports disabled. If
  retention is re-enabled, update the manifest, policy, in-app copy, and App
  Store Connect answers before serving that configuration.

## Validation performed on the audited worktree

| Validation | Result |
| --- | --- |
| `./scripts/check-harc-protocol-schemas.sh` | Passed: 7 schemas, 6 services, 27 RPCs, 29 enums |
| Focused relay, bootstrap, Host adapter, and pairing-ticket Swift tests | Passed: 38 tests in 4 suites; Remote admission binding then passed 25 tests in 2 suites |
| `CloudflareRelay` type generation, typecheck, Vitest, and Wrangler dry run | Passed: 3 files / 12 tests; dry-run bundle generated |
| `./scripts/test-relay-inner-tls-emulator.sh` | Passed against a fresh local Worker: pinned TLS 1.3 bootstrap, authenticated Library snapshot, one-chunk reconciliation, resumed second chunk, and negative frame inspection |
| `xcodegen generate` | Passed |
| Unsigned arm64 macOS `Harc` Debug build, two workers | `BUILD SUCCEEDED`, including `harc-stt` and `harc-mcp` |
| Unsigned generic-device iOS `HarcMobile` Debug build, two workers | `BUILD SUCCEEDED` |
| Relay-enabled macOS `0.14.0 (55)` release candidate | Developer ID signed, Apple notarized and stapled, Gatekeeper accepted, relay origin verified, arm64-only app and helpers; Sparkle/GitHub publication not performed |
| Signed physical `HarcMobile` Debug build on Omega (`iPhone16,2`, iOS 26.6) | `BUILD SUCCEEDED` with Apple Development signing and the team provisioning profile |
| Physical `HarcMobileAppTests` on Omega | Passed: 21 tests, 0 failures, after correcting one stale privacy-copy expectation found by the first run |
| Physical `HarcMobileUITests` on Omega | Passed on 2026-08-09 after restarting Omega and re-authorizing Enable UI Automation: 3 tests, 0 failures, including physical microphone start/stop through the visible `Saved locally` state |
| Physical `HarcMobileSpikesTests` on Omega | Passed on the 2026-08-09 retry: 14 codec qualification guard tests, 0 failures. This validates the harness rules and physical XCTest service, not a three-hour codec cell. |
| App Store configuration/reviewer focused tests on Omega | Passed 17/17 after packaging the public HTTPS privacy-policy link: 13 configuration tests and 4 offline-review/privacy tests |
| HarcMobile Release build settings | Confirmed iOS 18, iPhone-only, `SKIP_INSTALL=NO`, `.app`, expected bundle/version/build, automatic signing, and AppIcon slot; the final icon asset and exact clean archive remain open |
| Read-only ordinary phone-state checkpoint | Two finalized masters remained present on Omega. One capture was local-only and one recoverably failed after a completed durable batch; no verified recording receipt existed, so neither master was deleted. Normal relaunch did not advance the transfer while the production codec gate remained closed. |
| App Store artifacts | Direct-App-Store runbook, paste-ready metadata/App Review notes, five-image screenshot plan, and dated pass/open matrix prepared; public support/contact and account-owner fields remain open |
| Relay production deployment | Persistent Workers Logs and Traces disabled; Wrangler types/check, 3 files/12 tests, startup profile, and dry-run passed; version `6aee297a-49ea-4f92-8dab-3bdad4037976` deployed to the custom domain and `/health` returned `{"status":"ok"}` |
| `git diff --check` | Passed |

After the operating floor was lowered to 5 GiB, the current SwiftPM worktree
completed a full bounded run. The build-loaded pass reported one timing issue;
the immediate full no-build rerun passed all 1,540 Swift Testing cases in 259
suites plus 123 XCTest cases, with four real-model cases skipped by their
explicit opt-in contract. The load/no-load contrast matches the repository's
documented timing-flake rule. Free space remained approximately 10 GiB.

## Go/no-go rule

- **Standalone macOS and direct private validation:** architecture is good;
  continue with focused hardening and current regression discipline.
- **Mac Host/client and Harc Remote:** approved for general release in Harc
  0.14.0. Harc Remote remains opt-in and direct LAN remains preferred.
- **iPhone App Store distribution:** tracked separately from the macOS and relay
  release decision.

The next engineering investment remains evidence-driven hardening: production
load/cost monitoring, privacy-observability evidence, physical mobile
qualification, and repeated secondary-Mac scenarios.
