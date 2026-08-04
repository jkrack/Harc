# Host, Client, and Mobile Release-Gate Audit

**Date:** 2026-08-04

**Branch:** `codex/host-client-mobile`

**Specification:** [2026-08-02 Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Decision

The local software gate for PRs 0 through 9 is green. The branch compiles as a
bounded arm64 macOS app and iOS Simulator app, its standalone,
application-hosted, and UI tests pass, and its reviewer-accessible sample,
privacy source, and Beta Review notes are implemented. The remaining completion
claims require hardware or account-owned release metadata that was not
available in this run.

This audit therefore supports a signed macOS build candidate. It does not
support claiming the local-network iPhone alpha, useful mobile beta,
edge-capable secondary-Mac system, or external TestFlight release complete.

## Requirement reconciliation

| Spec slice | Local evidence | Remaining acceptance evidence |
| --- | --- | --- |
| PR 0-2 | Baseline, stable IDs/migrations, capture/publication seams, and standalone regression are implemented and covered by the full SwiftPM suite. | None for the local source gate. |
| PR 3-5 | Identity, client/host stores, protobuf signing contracts, canonical ingest, durable receipts, kill-point recovery, and codec-neutral fixture coverage pass locally. | A shipping lossless mobile codec remains fail-closed until physical CAF/ALAC qualification is recorded. |
| PR 6 | Pinned TLS/gRPC, narrow HTTPS, Bonjour, session/capability handling, resident Host lifecycle, and authenticated local MCP are implemented and exercised by transport/application tests. | Physical delayed-background, DHCP/route-change, and TLS-cutover runs remain open. |
| PR 7 | iPhone shell, QR adoption, protected durable capture, format-changing engine/tap/converter rebuilds with visible discontinuities, standalone playback/export, persistent outbox, request-bound background upload, relaunch reconciliation, and adopted-Host route recovery are implemented. | Physical C1-C7 and T1-T7/P1/H1 remain open; C1, C2, T1, and T2 require three consecutive runs on oldest and current supported iPhones. |
| PR 8 | Snapshot/delta library sync, search/detail, verified playback/cache, status, conflict handling, signed metadata/speaker mutations, and capture-interruption UI are implemented. | End-to-end useful-mobile-beta UX must be exercised on a physical iPhone. |
| PR 9 | Secondary-Mac pairing/outbox, local processing, signed edge artifacts, Host arbitration, cache policy, and separate On This Mac ownership are implemented. | A real second Mac must pair, record/transcribe locally, upload concurrently, and show Host acceptance or visible reprocessing. |
| PR 10 | Intentionally optional and deferred by the specification. | No release claim depends on it. |

## Local gate results

| Gate | Result |
| --- | --- |
| Focused durable capture recovery | 9 tests in 3 suites passed, including deterministic storage-exhaustion recovery and writer-failure truncation to the synchronized checkpoint. |
| Full SwiftPM regression | 1,499 Swift Testing cases in 253 suites and 121 XCTest cases passed with two workers. Thirteen real-model/model-quality cases remained opt-in by contract. |
| HarcMobile app tests | 18/18 passed on arm64 iPhone 17 Pro Simulator, iOS 26.5, including no-tracking/no-collection plus the required app-container file-metadata reason, export metadata, Simulator backup exclusion, format-changing converter rebuild, terminated-pipeline race coverage, the C7 qualification hook/UI state, and isolated canonical reviewer content. |
| HarcMobile UI tests | 2/2 passed with normal Simulator ad-hoc signing and UUID-scoped Application Support/Keychain state. They verify explicit recording disclosure/readiness and navigate the unpaired app to the offline review sample and Privacy & Data surface. |
| HarcMobile qualification-logic tests | 14/14 passed on the same Simulator. Schema-5 reports now bind evidence to unique report/process IDs, version/build, signing team, and source SHA while continuing to reject Simulator evidence. |
| Physical codec matrix validator | 10/10 focused `harcctl` tests passed. A real schema-5 quick-mode Simulator report was rejected before matrix acceptance; reused processes, device/build drift, and threshold drift also fail closed. |
| Generic iOS Simulator build | Passed with arm64 and two-worker limits. |
| Unsigned macOS app build | Passed with arm64 and two-worker limits, including embedded helpers. |
| Release-script preflight | Passed with two workers, including Developer ID inside-out signing, DMG signature/checksum, and the new mounted packaged-app deep-signature gate. |
| TestFlight code-owned artifacts | Offline read-only reviewer sample, synthetic WAV, stable accessibility identifiers, in-app privacy copy, privacy-policy source, App Privacy/export rationale, external checklist, and Beta App Review notes are present and locally tested. |
| Slice-boundary hygiene | The obsolete public `commitUploadUnavailableUntilPR5` sentinel and its error-mapping/test path were removed; production Host upload errors no longer expose superseded PR-phase state. |
| Source hygiene | `git diff --check` passed. |

## Physical C7 storage-exhaustion hook

The Debug iPhone app accepts these launch arguments for the C7 physical test:

```text
--harc-capture-storage-exhaustion-after-canonical-bytes 160000
```

After at least five seconds of canonical PCM has reached a durable checkpoint,
the next writer append deterministically returns `ENOSPC`. The expected result
is a visible **iPhone storage is full** terminal state, one playable nonempty
durable prefix finalized as `storageExhausted`, `writerFailure` and `recovery`
discontinuities, and no zero-byte success. Release builds ignore this argument.

## Gates that remain open

- No physical iPhone was attached (`xcrun devicectl list devices` returned no
  devices), so the production codec switch remains intentionally disabled and
  the physical capture/background-transfer matrix cannot be signed off. The
  four-cell, fresh-process procedure and command are recorded in
  `docs/operations/mobile-physical-qualification.md` for execution when the
  oldest and current supported iPhones are attached.
- No second Mac participated in this run, so PR 9's real edge-system gate is
  open.
- External TestFlight still requires physical verification of recording consent
  and persistent indication, VoiceOver/largest-Dynamic-Type and upgrade/recovery
  evidence, a public privacy-policy URL, monitored feedback/review contacts,
  exact archive metadata, confirmation that the uploaded build still matches
  the App Privacy/export answers, and the external TestFlight review itself.
  The reviewer-accessible offline sample and Beta App Review notes are no longer
  missing code-owned artifacts.

These are evidence gates, not reasons to weaken the fail-closed codec, trust,
or receipt policies.

## Signed macOS 0.13.0 candidate

The replacement candidate was built from source commit `bf38831` with two
workers, Developer ID signing, hardened runtime, secure timestamps, and an
arm64-only Harc application plus `harc-stt` and `harc-mcp` helpers.

| Candidate evidence | Value |
| --- | --- |
| Version/build | `0.13.0` / `45` |
| Notary submission | `3c0b02d1-da93-43be-8e2d-422c92af6d0e` |
| Apple result | `Accepted`; `Ready for distribution`; no issues |
| Uploaded pre-staple SHA-256 | `4fcca101f9ee73b14956c89a2a57e7efca2b8325c51cb4e36bad8e09b9500ae3` |
| Stapled candidate byte count | `64875781` |
| Stapled candidate SHA-256 | `d49d04f5c97e56492b33fbaea38c9b4539306c18b340633a98ead3c9a5700a54` |
| DMG CDHash | `f34a06ea9bde361a7d2ac50bd4de5caac7355278` |
| Harc app CDHash | `f94b64b2771159eacaac6e1884d79da31dcb33ce` |
| Sparkle EdDSA signature | `/e+5TRHJXOHVZvglks08nL5LhrTqi8E4EsfAJiDdoQEwhI82xH8sHfe4MFWBIGby9rM8/1/Xy9t6fhFNEmw9Bg==` |

`scripts/verify-release.sh` passed against the exact
`build/release-dist/Harc-local.dmg` bytes. It verified the outer code signature,
UDIF checksum, stapled ticket, Gatekeeper acceptance, mounted application and
nested-code signatures, notarized application assessment, bundle metadata, and
application/helper architectures. `Harc-0.13.0.dmg` and `Harc-local.dmg` have
the same SHA-256, and `Harc-local-dmg.zip` was generated from that stapled DMG.
Extracting `Harc-local.dmg` from the ZIP reproduced the same SHA-256, and
Sparkle's `sign_update --verify` accepted the recorded EdDSA signature against
the exact DMG bytes.

The first restricted verification attempt incorrectly reported unavailable
certificate authorities and invalid signatures because the sandbox could not
see the login-keychain trust chain. Repeating the same checks with normal macOS
trust access found two valid signing identities and accepted the unchanged app
and DMG. The release script now mounts and verifies the packaged app before
notarization, and the separate post-notarization verifier makes the required
trust boundary explicit.

The candidate and replacement appcast entry are prepared but not published.
Publishing still requires the deliberately separate main/tag/GitHub-release
operation, with these exact `Harc-local.dmg` bytes uploaded as the release asset.
