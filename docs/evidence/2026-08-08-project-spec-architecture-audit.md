# Harc project, specification, and architecture audit

**Date:** 2026-08-08

**Reviewed source:** `main` implementation candidate
`bcaba87283d1d9c80315e4e432310da8a04602e6` for Harc Remote, pairing,
mobile-codec, App Store, and privacy work for 0.14.1 (56)

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
feature of the resident Mac Host. Hardened Worker version
`6aee297a-49ea-4f92-8dab-3bdad4037976` is live at `relay.adaptcontext.com`.
Harc 0.14.1 (56), carrying that origin, is published from tagged commit
`1ef2c8669886c4898e9780d3606810a3ee1523fe` with the signed appcast and both
required GitHub release assets. The exact published DMG is Developer ID signed,
notarized, stapled, Gatekeeper accepted, and SHA-256
`871ab1b59f90694884340049d15f16b5ec837f78b453b2c0c994519ed7b17146`.
This supersedes this audit's earlier Harc Remote no-go conclusion. Staging load,
pricing, overload/redeployment, pinned-inner-TLS, safe-redaction, and relay
lifecycle evidence now pass. Physical two-network/direct-route/revocation and
old-record expiry remain operational gates. Secondary-Mac Client and iPhone App
Store distribution remain separate release decisions.

## Specification trace

| Surface | Finding | Evidence or remaining gate |
| --- | --- | --- |
| Private, local-first inference | Conforms | Standalone capture, storage, STT, and summarization remain local. Adopted-Host processing is explicit. Optional relay forwards encrypted bytes and is not a processor or backup. |
| Menu-bar and long-form reliability | Conforms | Existing macOS capture and recovery architecture remains authoritative; no reviewed change makes optional Host, mobile, or relay availability a capture prerequisite. |
| Domain and wire boundary | Conforms | `HarcDomain`, `HarcIdentity`, generated `HarcProtocolWire`, and validated `HarcProtocol` remain separated. The schema guard rejects filesystem/database identifiers and passed in this audit. |
| Host authority and durable publication | Conforms in source | Canonical ingest, publication journal, receipts, and recovery remain Host-owned. Audio safety is acknowledged before derived processing. |
| Pairing and session security | Conforms for direct transport | Device proof, pinned TLS, short-lived/single-use pairing, human comparison, foreground Host approval, signed objects, and scoped capabilities remain layered rather than collapsed into transport security. |
| iPhone capture and transfer | Source-complete; physical diagnostics started | Protected master, persistent outbox, immutable batches, background-task reconciliation, verified receipt, local playback, and explicit export are implemented. A signed build, all 24 hosted app tests, and all 6 UI tests passed on Omega (`iPhone16,2`, iOS 26.6), but the required physical C/T/P/H matrix has not passed. |
| Mobile lossless codec | Correctly fail-closed | Production selection still requires `HARC_MOBILE_QUALIFIED_CAF_ALAC`. The only full CAF+ALAC hardware run was bit-exact but failed the frozen thermal rule; the four-cell matrix is incomplete. |
| Mobile Library | Conforms in source | Snapshot/delta cache, playback, mutations, conflicts, and speaker identities preserve Host canonical ownership. The offline reviewer/Privacy path and native accessibility audit pass physically; manual VoiceOver, useful-beta, and remaining physical qualification stay open. |
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

- The implementation candidate is now sealed at
  `bcaba87283d1d9c80315e4e432310da8a04602e6`. Use that exact source identity
  for the three-hour codec cells and preserve the resulting reports.
- Keep Omega (`iPhone16,2`, iOS 26.6) connected and connect the named
  oldest-supported iPhone. Omega was the only physical iPhone visible to Xcode
  during this audit.
- Run the required C1-C7, T1-T7/T2b-T2e, P1, and H1 scenarios on the named
  physical iPhones, including three successful repetitions where the contract
  requires them.
- Repeat all four physical codec cells (oldest/current non-Pro iPhone times
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

- Run the two-network iPhone/Mac, direct-route recovery, and visible revocation
  scenarios as release evidence. The staging `4429 receiver_overloaded`
  forced-close/redeployment, 1,000-idle-Host load/pricing, real inner-TLS, safe
  aggregate redaction, and relay-level reconnect/revocation exercises pass.
- Confirm that records from the superseded sampled-observability configuration
  are absent on or after 2026-08-16 before freezing the App Store privacy answer.
- Keep persistent Workers Logs, Traces, and per-request exports disabled. If
  retention is re-enabled, update the manifest, policy, in-app copy, and App
  Store Connect answers before serving that configuration.

## Validation performed on the audited worktree

| Validation | Result |
| --- | --- |
| `./scripts/check-harc-protocol-schemas.sh` | Passed: 7 schemas, 6 services, 27 RPCs, 29 enums |
| Focused relay, bootstrap, Host adapter, and pairing-ticket Swift tests | Passed: 38 tests in 4 suites; Remote admission binding then passed 25 tests in 2 suites |
| `CloudflareRelay` type generation, typecheck, Vitest, and Wrangler dry runs | Passed: production and observer generated types, 4 files / 17 unit tests plus 1 Durable Object integration test, and both dry-run bundles |
| `./scripts/test-relay-inner-tls-emulator.sh` | Passed against a fresh local Worker: pinned TLS 1.3 bootstrap, authenticated Library snapshot, one-chunk reconciliation, resumed second chunk, and negative frame inspection |
| `xcodegen generate` | Passed |
| Unsigned arm64 macOS `Harc` Debug build, two workers | `BUILD SUCCEEDED`, including `harc-stt` and `harc-mcp` |
| Unsigned generic-device iOS `HarcMobile` Debug build, two workers | `BUILD SUCCEEDED` |
| Published relay-enabled macOS `0.14.1 (56)` | Repository release verifier passed the exact 66,149,395-byte published DMG: Developer ID signed, Apple notarized and stapled, Gatekeeper accepted, bundle `com.harc.Harc`, relay origin verified, arm64-only app/helpers, SHA-256 `871ab1b59f90694884340049d15f16b5ec837f78b453b2c0c994519ed7b17146`. Appcast length and signature are published at tag `v0.14.1`; GitHub contains the exact DMG and ZIP, whose server digests match the local release artifacts. See [Harc 0.14.1 release evidence](2026-08-09-0.14.1-release.md). |
| Signed physical `HarcMobile` Debug build on Omega (`iPhone16,2`, iOS 26.6) | After regenerating from `project.yml`, HarcMobile 0.14.1 (56) built with Apple Development signing and the team provisioning profile; CoreDevice confirmed that exact version/build installed afterward |
| Physical `HarcMobileAppTests` on Omega | Current candidate 0.14.1 (56) passed: 24 tests, 0 failures and 0 skips, including the physical Data Protection/backup-exclusion round trip and the fail-closed exact-root reset parser |
| Physical `HarcMobileUITests` on Omega | Current candidate 0.14.1 (56) passed: 6 tests, 0 failures and 0 skips, including a clean native accessibility audit of Record/Review/Privacy, physical microphone start/stop through `Saved locally`, C5 force-quit recovery, and C7 storage exhaustion |
| Physical `HarcMobileSpikesTests` on Omega | Passed on the 2026-08-09 retry: 14 codec qualification guard tests, 0 failures. This validates the harness rules and physical XCTest service, not a three-hour codec cell. |
| App Store configuration/reviewer focused tests on Omega | Passed 17/17 after packaging the public HTTPS privacy-policy link: 13 configuration tests and 4 offline-review/privacy tests |
| Compact iPhone simulator diagnostic | Passed 25 runnable tests with one physical-microphone skip on an arm64 iPhone SE (3rd generation), iOS 26.5 simulator at 375 x 667 points. A second focused run at `accessibility-extra-extra-extra-large` passed both applicable UI tests with one physical-microphone skip and zero failures after hardening scroll reachability. This validates compact layout/bootstrap and a largest-text diagnostic only; oldest-device, codec, thermal, physical accessibility, and C/T/P/H gates remain open. |
| Physical storage-policy diagnostic | Passed 1/1 on Omega (`iPhone16,2`, iOS 26.6): active-master, transfer-artifact, transfer-DB, and Library-DB production policies each round-tripped the required Data Protection class and backup exclusion. This is additional Pro-device current-source evidence; locked/reboot/first-unlock, upgrade, both named matrix devices, and exact-archive qualification remain open. |
| Physical C7 diagnostic | Passed 1/1 on Omega with visible storage-full/durable-prefix UI. Read-only isolated state proved a playable 5.098-second/81,568-frame master, exact canonical PCM hash agreement, `storageExhausted`, explicit writer-failure/recovery discontinuities, one present local-only row, and no receipt or cleanup intent. Oldest-device and sealed-build repetition remain open. |
| Physical C5 diagnostic | Passed 1/1 on Omega: a real capture was terminated after a durable checkpoint, relaunch visibly recovered one recording, and read-only isolated state proved a playable 5.098-second/81,568-frame master, exact canonical PCM hash agreement, `recoveredDurablePrefix`, an explicit recovery boundary, one present local-only row, and no receipt or cleanup intent. Randomized timing, oldest-device, and sealed-build repetition remain open. |
| Mobile UI-test repeatability hardening | Debug-only reset is restricted to one canonical UUID-scoped test root, rejects duplicate or unscoped requests, cannot reset normal or Release storage, and is omitted from the C5 relaunch so interrupted state survives. The complete simulator UI suite passed all three applicable tests and correctly skipped three physical-only tests; the complete physical rerun passed 30/30. Read-only C5/C7 copies each contained exactly one finalized capture and local-only outbox row with no upload attempt, receipt, or cleanup intent. |
| Mobile native accessibility audit | Passed without ignored findings on both the simulator and Omega for Record, offline Review Sample, and Privacy after hardening action/disclosure/header contrast, review metadata scaling, and the sheet close control. Manual VoiceOver traversal remains a separate release gate. |
| HarcMobile Release build settings | Confirmed iOS 18, iPhone-only, `SKIP_INSTALL=NO`, `.app`, expected bundle/version/build, automatic signing, and AppIcon slot; the opaque 1024-by-1024 icon source passes repository preflight, while the exact clean archive remains open |
| Read-only ordinary phone-state checkpoint | Two finalized masters remained present on Omega. One capture was local-only and one recoverably failed after a completed durable batch; no verified recording receipt existed, so neither master was deleted. Normal relaunch did not advance the transfer while the production codec gate remained closed. |
| App Store artifacts | Direct-App-Store runbook, paste-ready metadata/App Review notes, five-image screenshot plan, and dated pass/open matrix prepared; public support/contact and account-owner fields remain open |
| Relay deployment evidence | Production version `6aee297a-49ea-4f92-8dab-3bdad4037976` is active at 100% with disabled persistent observability and a zero-record dashboard query. Distinct staging passed real `4429` overload, 1,000/1,000 idle Hosts plus active transfer, pinned-TLS Library/reconciliation/resume, and safe aggregate redaction. Restored staging version `6d537995-70ea-40d0-aed7-4442d93a0efa` also passed Host-offline, same-route reconnect, replacement session, revocation, stale-capability rejection, reauthorization, final privacy, and health. Account-scoped Logpush shows no jobs. Raw tail remains prohibited; physical two-network/direct-route/visible-revocation and sampled-record expiry after 2026-08-16 remain open. |
| `git diff --check` | Passed |

After the operating floor was lowered to 5 GiB, the current SwiftPM worktree
completed a full bounded run. The build-loaded pass reported one timing issue;
the immediate full no-build rerun passed all 1,541 Swift Testing cases in 259
suites plus 123 XCTest cases, with four real-model cases skipped by their
explicit opt-in contract. The load/no-load contrast matches the repository's
documented timing-flake rule. Free space remained approximately 10 GiB.

## Go/no-go rule

- **Standalone macOS and direct private validation:** architecture is good;
  continue with focused hardening and current regression discipline.
- **Resident Mac Host and Harc Remote:** approved for general release in Harc
  0.14.1. Harc Remote remains opt-in and direct LAN remains preferred.
- **Secondary-Mac Client:** architecture and source conform, but general release
  remains no-go until the real second-Mac PR 9 qualification passes.
- **iPhone App Store distribution:** tracked separately from the macOS and relay
  release decision.

The next engineering investment remains evidence-driven hardening:
old-record/account-export privacy closeout, physical two-network/direct-route behavior,
physical mobile qualification, and repeated secondary-Mac scenarios. The initial production
load/cost feasibility gate is complete; ongoing monitoring remains operational.
