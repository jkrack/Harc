# Host, Client, and Mobile Release-Gate Audit

**Date:** 2026-08-04

**Branch:** `codex/host-client-mobile`

**Specification:** [2026-08-02 Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Decision

The local software gate for PRs 0 through 9 is green. The branch compiles as a
bounded arm64 macOS app and iOS Simulator app, its standalone and
application-hosted tests pass, and the remaining completion claims require
hardware or external release metadata that was not available in this run.

This audit therefore supports a signed macOS build candidate. It does not
support claiming the local-network iPhone alpha, useful mobile beta,
edge-capable secondary-Mac system, or external TestFlight release complete.

## Requirement reconciliation

| Spec slice | Local evidence | Remaining acceptance evidence |
| --- | --- | --- |
| PR 0-2 | Baseline, stable IDs/migrations, capture/publication seams, and standalone regression are implemented and covered by the full SwiftPM suite. | None for the local source gate. |
| PR 3-5 | Identity, client/host stores, protobuf signing contracts, canonical ingest, durable receipts, kill-point recovery, and codec-neutral fixture coverage pass locally. | A shipping lossless mobile codec remains fail-closed until physical CAF/ALAC qualification is recorded. |
| PR 6 | Pinned TLS/gRPC, narrow HTTPS, Bonjour, session/capability handling, resident Host lifecycle, and authenticated local MCP are implemented and exercised by transport/application tests. | Physical delayed-background, DHCP/route-change, and TLS-cutover runs remain open. |
| PR 7 | iPhone shell, QR adoption, protected durable capture, visible discontinuities, standalone playback/export, persistent outbox, request-bound background upload, relaunch reconciliation, and adopted-Host route recovery are implemented. | Physical C1-C7 and T1-T7/P1/H1 remain open; C1, C2, T1, and T2 require three consecutive runs on oldest and current supported iPhones. |
| PR 8 | Snapshot/delta library sync, search/detail, verified playback/cache, status, conflict handling, signed metadata/speaker mutations, and capture-interruption UI are implemented. | End-to-end useful-mobile-beta UX must be exercised on a physical iPhone. |
| PR 9 | Secondary-Mac pairing/outbox, local processing, signed edge artifacts, Host arbitration, cache policy, and separate On This Mac ownership are implemented. | A real second Mac must pair, record/transcribe locally, upload concurrently, and show Host acceptance or visible reprocessing. |
| PR 10 | Intentionally optional and deferred by the specification. | No release claim depends on it. |

## Local gate results

| Gate | Result |
| --- | --- |
| Focused durable capture recovery | 8 tests in 3 suites passed, including writer-failure truncation to the synchronized checkpoint. |
| Full SwiftPM regression | 1,498 Swift Testing cases in 253 suites and 121 XCTest cases passed with two workers. Thirteen real-model/model-quality cases remained opt-in by contract. |
| HarcMobile app tests | 5/5 passed on arm64 iPhone 17 Pro Simulator, iOS 26.5. |
| HarcMobile qualification-logic tests | 11/11 passed on the same Simulator and continue to reject Simulator evidence for the physical codec gate. |
| Generic iOS Simulator build | Passed with arm64 and two-worker limits. |
| Unsigned macOS app build | Passed with arm64 and two-worker limits, including embedded helpers. |
| Source hygiene | `git diff --check` passed. |

## Gates that remain open

- No physical iPhone was attached (`xcrun devicectl list devices` returned no
  devices), so the production codec switch remains intentionally disabled and
  the physical capture/background-transfer matrix cannot be signed off.
- No second Mac participated in this run, so PR 9's real edge-system gate is
  open.
- External TestFlight still requires verified recording consent and persistent
  indication, accessibility and upgrade/recovery evidence, a public privacy
  policy URL, matching App Privacy/export answers, a reviewer-accessible sample
  path, and Beta App Review notes.

These are evidence gates, not reasons to weaken the fail-closed codec, trust,
or receipt policies.

## Signed macOS 0.13.0 candidate

- Source commit: `35645e7` (the later appcast-only release commit does not
  change application bytes).
- Build: arm64 Release, Developer ID Application, hardened runtime and secure
  timestamps, with embedded `harc-stt`, `harc-mcp`, and Sparkle verified
  inside-out.
- Apple notarization submission:
  `0c555d91-3b1e-4fac-9eea-057d35458851`, status **Accepted**.
- Stapler validation: passed.
- Gatekeeper: `accepted`, `source=Notarized Developer ID`.
- Published DMG asset size: 64,876,221 bytes.
- Published DMG SHA-256:
  `e109a09970cc680fad489d380af095dc833e9103bf18927539efbb5d7d67bd4a`.
- The Sparkle EdDSA entry was generated only after stapling and covers those
  exact `Harc-local.dmg` bytes.
