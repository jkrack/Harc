# HarcMobile App Store readiness evidence

**Date:** 2026-08-13
**Candidate configuration:** HarcMobile 0.14.3 (58), iOS 18+, iPhone only
**Device available:** Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6

## Decision

**The App Store preparation path is valid, but the app is not ready to submit.**

The architecture and local build/test posture do not need a redesign. The
reviewer-accessible offline path, truthful privacy copy, release settings,
submission copy, and final icon source are now present. Remaining no-go items
are measurable physical, archive, privacy-account, screenshot, and
account-owner gates rather than architectural uncertainty.

## 0.14.3 current-tree refresh

The shipping macOS 0.14.3 source tag is `v0.14.3` at
`cdc0708f0576eea40b0d2e95d05dd4ff4ffca052`. The local Host completed its
Sparkle update and passed strict signature and Gatekeeper verification. A
signed 0.14.3 physical run on Omega passed all 24 hosted HarcMobile app tests,
including Data Protection, backup exclusion, route-change capture policy,
bounded handoff, packaged privacy metadata, and deterministic background-batch
checks. Current source additionally shares verified direct/relay selection
between desktop and mobile and shows an authenticated Host-health indicator.
On 2026-08-13, `xcodegen generate` and a bounded arm64 iOS Simulator
`build-for-testing` compiled and linked the app, hosted tests, and UI tests with
`TEST BUILD SUCCEEDED`.

The six physical UI tests did not execute in this refresh: both the initial run
and one warm retry timed out while Xcode enabled device automation mode. Omega
remained wired, paired, booted, Developer Mode enabled, and unlocked according
to CoreDevice. Preserve this as an external test-service gate, not an app test
failure and not a 0.14.3 UI pass. The complete 0.14.1 Omega UI evidence below
remains valid for that sealed source only.

The current relay source also passed the production/staging fail-closed privacy
guards, both generated-type checks, TypeScript, 17 Worker unit tests, one
redaction-observer integration test, and both Wrangler 4.120.0 dry-run bundles.
No deployment was performed.

## Pass/open matrix

| Gate | Status | Evidence or next action |
| --- | --- | --- |
| Architecture/specification review | **Pass** | The 2026-08-08 audit approves the Host-backed, durable-capture, receipt-before-processing architecture and optional untrusted relay boundary. |
| Full Swift package regression | **Pass** | 1,541 Swift Testing cases plus 123 XCTest cases passed on the bounded rerun; four real-model XCTest cases were intentionally opt-in skipped. The run found and then verified the 0.14.1 shared-version fallback correction. |
| macOS and iOS compilation | **Pass** | The isolated current-source snapshot passed a signed arm64 physical-iPhone build, an arm64 simulator test build, and the existing signed arm64 macOS `Harc` Debug build with two workers. `swift test` alone was not treated as app-target evidence. |
| iPhone signed build and smoke automation | **Sealed-source pass on available device** | The exact source now sealed at implementation commit `bcaba87283d1d9c80315e4e432310da8a04602e6` passed a signed bounded run on Omega: all 24 hosted app tests and all 6 UI tests, with zero failures or skips. UI coverage includes the native accessibility audit, ordinary microphone start/stop to **Saved locally**, C5 force-quit recovery, and C7 storage exhaustion. This is current-source evidence on the available Pro device, not completion of the two named qualification-device cells; the 14 spike-harness guard tests passed earlier but were not rerun in this exact 0.14.1 suite. |
| Compact iPhone layout/bootstrap | **Diagnostic pass** | A temporary iPhone SE (3rd generation), iOS 26.5 arm64 simulator passed 23 hosted app tests and both applicable UI tests at 375 x 667 points. A second UI run at `accessibility-extra-extra-extra-large` passed both applicable flows after hardening scroll reachability; the physical-microphone test was correctly skipped. This is compact-screen evidence, not an oldest-physical-device, codec, thermal, physical-accessibility, or C/T/P/H result. |
| Ordinary phone-state checkpoint | **Diagnostic pass for retention; transfer gate open** | A read-only copy found two present finalized masters, no receipt or cleanup, one local-only outbox, and one recoverably failed outbox after a completed batch. Relaunch preserved the artifacts; production transfer remains fail-closed until codec qualification. |
| Reviewer path | **Pass in source and physical UI** | **Library > Open Offline Review Sample** works without an account, Host, permissions, user data, state writes, or networking. |
| Privacy manifest | **Structurally valid; deployed config aligned; expiry/owner closeout open** | Packaged manifest declares no tracking/collected data and file-timestamp reason `C617.1`. Production read-back proves Logpush off, no Tail Workers, and observability disabled on the single 100% Worker version; dashboard queries found zero relay events/traces after the change, and Account-scoped Logpush shows no jobs. Prior sampled-record expiry on/after 2026-08-16 and Account Holder exact-build confirmation remain gates. |
| Public privacy-policy surface | **Pass in source, physical UI, and publication** | The packaged HTTPS policy URL is displayed under **Privacy & Data**, copied into the metadata deck, passed the configuration assertion on Omega, and resolves publicly with HTTP 200. |
| Public support surface | **Pass in source and publication** | The stable support page contains product help, a privacy warning, issue intake, and the Account Holder-provided monitored contact `support@cloudarchitech.com`. Repository preflight verifies that the visible address and `mailto:` target agree, and the public page on `main` contains the same contact. GitHub Issues remain a secondary, public intake surface. |
| Release configuration | **Pass** | Release settings resolve to bundle `com.harc.HarcMobile`, iOS 18.0, iPhone family 1, `SKIP_INSTALL=NO`, `.app`, automatic signing, no Catalyst or Designed-for-iPhone-on-Mac distribution, complete Data Protection, and non-exempt encryption false. |
| Broad capture versus optional inference tier | **Pass in architecture/source; physical floor open** | The normative contract and packaged metadata prohibit a hidden device-model capability gate for capture/storage/transfer/Library. Optional inference must fall back to the Host. No model identifier or mobile inference dependency exists in the capture path; the oldest declared launch iPhone still requires physical qualification. |
| App Store metadata/review copy | **Prepared** | Name, subtitle, promotional text, description, keywords, URLs, review path, and background/permission notes are in `docs/app-store/harcmobile-metadata.md`. Account-owner fields remain explicit. |
| Screenshots | **Three of five native sources pass** | Release-configured iPhone 15 Pro Max capture produced visually reviewed, opaque 1290-by-2796 images for ready-to-record, offline review sample, and Privacy & Data. Active recording remains a physical-Omega capture because simulator RemoteIO aborts; Host Library detail remains open until a purpose-made non-sensitive Host fixture exists. No state is mocked and no personal Library data is used. |
| App icon | **Pass in source and archive** | `HarcMobileApp/Assets.xcassets` contains the established Harc artwork as one opaque 1024-by-1024 universal iOS AppIcon source. Repository preflight validates dimensions and absence of alpha; the exact archive contains the compiled asset catalog and `AppIcon` primary-icon metadata. |
| Exact clean archive and upload | **Archive and distribution export pass; upload open** | Clean pushed commit `143ba41ff21c7c6ba6d17b0a2d9dc5285f9ac07f` produced a signed 0.14.1 (56) arm64 archive. Every archive-specific verifier passed, and the exact app installed and launched on Omega. A local App Store Connect export then passed every distribution-signature/profile/entitlement check. Upload and App Store processing remain open behind the physical and owner-input gates. |
| Physical codec qualification | **Blocked by evidence inputs** | Four real-time three-hour cells require a clean sealed build and both named matrix phones: an iPhone XR on iOS 18 as the oldest eligible target and a current non-Pro iPhone 17 on current iOS. Omega is additional Pro-hardware evidence and satisfies neither named role. Production codec remains fail-closed until both required devices pass. |
| C/T/P/H physical matrix | **Open; repeatable Omega C5/C7 diagnostics pass** | Omega passed deterministic C5 force-quit/relaunch recovery and C7 storage exhaustion. Each now starts from a reset, exact UUID-scoped Debug test root and produced exactly one playable 5.098-second durable prefix with exact PCM hash agreement, explicit recovery accounting, a present local-only master, and no receipt/cleanup; C7 also showed the required storage-full terminal state. C1-C4, C6, T1-T7, T2b-T2e, P1, H1, both named-device C5/C7 cells, randomized C5 coverage, and sealed-build repetition remain; C1, C2, T1, and T2 require three consecutive passes on both named devices. |
| Accessibility, upgrade, and protection qualification | **Open; automated audit, largest-text, and physical storage diagnostics pass** | The native XCTest audit reports no findings on Record, offline Review Sample, or Privacy on both the simulator and Omega after contrast, scalable-metadata, and close-control hardening. Both applicable compact-screen UI flows also pass at the simulator's largest Dynamic Type setting. On Omega, active-master, transfer-artifact, transfer-DB, and Library-DB policies round-tripped their exact Data Protection classes and backup exclusion. Manual VoiceOver traversal, physical largest-text and locked/reboot behavior, interrupted transfer, installed-build upgrade/recovery, and exact-archive repetition remain open. |
| Secondary Mac | **Open** | A real second Mac must pair, process locally, upload concurrently, and visibly resolve Host acceptance/reprocessing without library merging. |
| Harc Remote inner TLS | **Pass locally** | Fresh-emulator pinned TLS 1.3 bootstrap, Library, resumable upload, reconciliation, and negative plaintext inspection passed. |
| Harc Remote staging/load/privacy | **Inner TLS, load, lifecycle, safe redaction, overload/redeploy, and deployed no-retention pass; final external evidence open** | The 1,000-Host/current-plan and pinned-TLS application gates pass. Real staging also passed Host-offline, same-route reconnect, replacement session, revocation, stale-capability rejection, and reauthorization. The aggregate-only observer discarded all canaries/secret fields and was detached/deleted. Restored version `6d537995-70ea-40d0-aed7-4442d93a0efa` passes privacy/health. Confirm old-record/account-export expiry and run physical two-network/direct-route/visible-revocation evidence. |
| Account/commerce submission fields | **Open, Account Holder** | Support contact/page, review contact, age rating, category, pricing, regions, agreements, privacy answers, export answers, and manual-release selection must be completed in App Store Connect. |

## Launch hardware interpretation

The iOS 18 deployment floor does not prove performance on every iOS 18-capable
iPhone. Core capture, transfer, playback, and Library behavior should remain the
broad compatibility tier. Optional on-device inference must use a separately
measured capability/performance tier and must never make recording unavailable.

Omega is valid additional high-end physical evidence. It is neither the
oldest-device cell nor the specification's current non-Pro cell. With the
current iOS 18 deployment target, older eligible iPhones can install the app; a
marketing-only model restriction would not make the binary safe on those
devices. If the recommended physical iPhone XR/iOS 18 and current non-Pro
iPhone 17/current-iOS targets cannot be acquired or borrowed, the release
remains blocked on that matrix. Do not add an unrelated required-device
capability solely to mask missing evidence.

The iPhone SE (3rd generation) simulator diagnostic proves the app can bootstrap
and expose its critical reviewer paths in the compact 375 x 667-point layout,
including at the simulator's largest Dynamic Type setting. It does not change
the physical-hardware conclusion above.

## Focused validation added in this pass

| Validation | Result |
| --- | --- |
| Public privacy URL reachability | HTTP 200 at the exact packaged GitHub policy URL |
| App Store copy limits | Name/subtitle within 30 characters; promotional text 153/170 characters; keywords 79/100 bytes; description below 4,000 characters |
| `xcodegen generate` | Passed after adding the packaged privacy-policy URL |
| Release `-showBuildSettings` | Confirmed iOS 18, iPhone-only, `SKIP_INSTALL=NO`, `.app`, expected bundle/version/build, automatic signing, and final AppIcon slot |
| Current-candidate physical app/UI run | Regenerated from `project.yml`; Debug settings resolved to 0.14.1 (56), bundle `com.harc.HarcMobile`, iOS 18, iPhone family 1, and `SKIP_INSTALL=NO`. The signed bounded run passed 30/30 on Omega with zero failures or skips, and CoreDevice confirmed HarcMobile 0.14.1 (56) installed afterward. |
| Focused physical app tests on Omega | Passed 17/17: 13 configuration tests and 4 offline-review/privacy tests, including packaged HTTPS policy, privacy wording, and the architecture-only device-capability assertion; xcresult `Test-HarcMobile-2026.08.09_08-05-12--0700.xcresult` |
| Compact-screen simulator regression | Passed 25/25 runnable tests with one physical-microphone skip on an arm64 iPhone SE (3rd generation), iOS 26.5 simulator at 375 x 667 points; hardened Record-tab test isolation and simulator/device metadata expectations; see `docs/evidence/2026-08-09-harcmobile-se3-compact-simulator.md` |
| Compact largest-text UI regression | Passed 2/2 applicable UI tests with one physical-microphone skip and zero failures at `accessibility-extra-extra-extra-large`; hardened scroll reachability for review-sample audio and Privacy & Data; physical VoiceOver/largest-text qualification remains open |
| Native accessibility audit | Passed without ignored findings on the simulator and Omega for Record, offline Review Sample, and Privacy. Hardened white-on-action-blue contrast, secondary disclosure/header contrast, scalable review metadata, and the Review Sample close control. This augments but does not replace manual VoiceOver traversal. |
| Physical storage-policy round trip | Passed 1/1 on Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6: active masters, transfer artifacts/DB, and Library DB each round-tripped the required physical Data Protection class plus backup exclusion; exact-archive locked/reboot/upgrade qualification remains open |
| Physical C7 storage exhaustion | Passed 1/1 on Omega with visible storage-full/durable-prefix UI; read-only state inspection proved one playable 5.098-second WAV, 81,568 frames, exact metadata/PCM hash agreement, `storageExhausted`, writer-failure/recovery markers, `localOnly`, and zero receipt/cleanup; oldest-device and sealed-build repetition remain open |
| Physical C5 force-quit recovery | Passed 1/1 on Omega: real capture was terminated after a durable checkpoint, relaunch visibly recovered one recording, and read-only state inspection proved one playable 5.098-second/81,568-frame WAV, exact metadata/PCM hash agreement, `recoveredDurablePrefix`, one recovery marker, `localOnly`, and zero receipt/cleanup; randomized timing, oldest-device, and sealed-build repetition remain open |
| Relay production-observability hardening | Target persistent logs/traces disabled; a fail-closed configuration guard, production/observer Wrangler type generation, TypeScript check, 4 files/17 unit tests plus 1 Durable Object integration test, and both dry-run bundles passed |
| Deployed relay privacy read-back | Passed at 2026-08-09 15:12 UTC: production version `6aee297a-49ea-4f92-8dab-3bdad4037976` at 100%, Logpush disabled, no Tail Workers, observability disabled, and live health OK; reproducible with `npm run privacy:deployed:check` |
| Deployed relay zero-record query | Passed for the post-change health interval at 15:18 UTC: Cloudflare Observability returned 0 Workers events and 0 traces for `scriptName = "harc-remote-relay"` over the preceding hour, after the documented ingestion-delay window |
| Relay staging overload/redeployment | Passed against distinct staging versions `f2998e42-4fdd-460d-9947-7fb63249c60f` and `df830ae2-434d-4096-a3da-6ba21f2621a7`: first frame relayed; both peers closed `4429 receiver_overloaded` on the unacknowledged second frame; health remained OK; deployed staging read-back proved no persistent observability; delayed dashboard queries returned zero retained staging events/traces |
| Relay staging load/cost | Passed 1,000/1,000 idle Host connections with zero retries, 30-second all-connected hold, 16-MiB/64-frame acknowledged transfer at 2.91 MiB/s, 214.09-MiB local generator peak RSS, healthy before/after, no platform resource/application errors, and counters within current Workers Paid monthly allowances; see `docs/evidence/2026-08-09-harc-remote-staging-load.md` |
| Relay staging inner TLS | Passed the real pinned TLS 1.3 bootstrap, authenticated Library snapshot, interrupted-upload reconciliation, and resumed upload through the deployed staging Worker; the repeatable wrapper refuses production and brackets the flow with deployed-privacy checks |
| Relay staging safe redaction | Passed an aggregate-only temporary observer over named canaries, overload, and pinned-TLS flows: 85 events reduced to counters, 261 headers/28 secret-header occurrences and six canary values discarded, no logs/exceptions/diagnostics/raw fields retained; observer detached/deleted, restored version passed privacy/health/overload, and delayed queries found zero events/traces |
| Relay staging lifecycle | Passed Host-offline admission, initial/replacement bidirectional acknowledged tunnels, same-route Host-control reconnect, revocation, stale-capability rejection, and replacement authorization against restored version `6d537995-70ea-40d0-aed7-4442d93a0efa`; final privacy/health and delayed zero-event/zero-trace checks passed |
| Final relay validation | `npm run check` passed privacy guard, both generated-type checks, TypeScript, 4 files/17 unit tests, 1 Durable Object integration test, and production/observer dry bundles; the staging dry bundle also passed; final deployed production/staging privacy and health read-backs passed after observer cleanup |
| Raw-tail privacy audit | Found Cloudflare real-time tail exposes request headers and network metadata. Raw tailing is prohibited. The passing replacement is a checked-in staging-only observer that persists fixed aggregate counters, restores staging before deletion, and fails closed if detachment fails. |
| Focused physical privacy-copy recheck | Passed 4/4 offline-review/privacy tests on Omega after the no-external-telemetry wording and production configuration change |
| Executable App Store preflight | The fail-closed repository/archive verifier covers disk floor, plists/privacy, release settings, icon properties, metadata limits, support URL/contact, exact archive contents, and a separate exported-app distribution-signing stage. It pins the exact Harc team/application identifier, requires a future profile expiration, and rejects device-bound or enterprise-wide profiles at distribution. The monitored support contact is now resolved in source; authoritative archive/distribution checks remain tied to the next sealed candidate. |
| Screenshot-set preflight | Added optional validation for the five versioned 1290 by 2796 App Store images, including exact filenames, dimensions, no alpha channel, and printed SHA-256 evidence. Temporary fixtures passed the complete image set, while independent wrong-dimension/alpha and missing-directory paths failed closed; the fixtures were removed. Final exact-build captures remain open. |
| Partial native screenshot capture | The opt-in Release UI test passed 1/1 on a dedicated iPhone 15 Pro Max/iOS 26.5 simulator and retained native images 01, 03, and 05. Visual inspection confirmed clean status bar, light appearance, no personal/security data, and truthful shipping UI. Each is 1290 by 2796 with no alpha. The first active-recording attempt captured image 01, then produced an AVFoundation RemoteIO simulator abort before the app could enter recording; image 02 therefore remains a physical-device gate rather than a fabricated simulator state. |
| Public-URL preflight | The optional live HTTPS check passes: the current pushed privacy-policy and support URLs return HTTP 200, and the published support page contains the approved monitored address with a matching `mailto:` target. |
| Cloudflare account export audit | Authenticated Account-scoped Logpush showed **No Logpush jobs**. A counts-only API audit was added for repeatability; current Wrangler OAuth lacks the separate Logs permission, so this run used the Account Holder dashboard. Historical sampled-record expiry remains open until 2026-08-16. |
| Deterministic UI-test state isolation | A Debug-only, exact UUID-scoped reset flag now clears only the selected test root before first launch; duplicate/missing-scope arguments fail closed, ordinary app storage and Release builds cannot be reset, and C5 relaunch intentionally preserves the same root. The full simulator UI suite passed all three applicable tests, including the native accessibility audit, while correctly skipping the three physical-only cases. |
| Complete Omega app/UI regression | HarcMobile 0.14.1 (56) passed 30/30 on Omega with no skips or failures: 24 hosted app tests and 6 UI tests, including the native accessibility audit, physical storage-class/backup checks, ordinary microphone capture, clean-root C5 recovery, clean-root C7 storage exhaustion, reviewer/privacy, and recording-entry disclosure. Fresh read-only copies of the deterministic C5/C7 roots each contained exactly one finalized capture, one local-only outbox row, one playable 5.098-second WAV, and zero upload attempts, receipts, or cleanup intents. Independently recomputed PCM hashes matched JSON and database metadata in both roots. This does not replace either named matrix phone. |
| Candidate-sealing local rerun | From one isolated copy of the final source tree, `npm run check` passed all relay privacy/type/test/dry-run gates; `swift test --jobs 2` passed 1,541 Swift Testing cases plus 123 XCTest cases with four declared real-model skips; the signed Omega run passed 24 app and 6 UI tests; the post-warning-cleanup UI rerun passed 6/6; the iPhone 17 simulator passed 24 app tests and all three applicable UI tests with exactly three physical-only skips; and the existing macOS `Harc` arm64 Debug target built successfully. Physical xcresults are `Test-HarcMobile-2026.08.09_14-26-15--0700.xcresult` and `Test-HarcMobile-2026.08.09_14-28-42--0700.xcresult`; simulator xcresult is `Test-HarcMobile-2026.08.09_14-30-37--0700.xcresult`. |
| Exact Release archive and Omega launch | Clean pushed commit `143ba41ff21c7c6ba6d17b0a2d9dc5285f9ac07f` produced the signed 355 MiB archive at 2026-08-09 15:04:57 -0700. All archive checks passed with executable SHA-256 `363addf6eca9f1d3c2165960f84a99b255d95fd85d6dec99c772b1e1f9832f59`, CDHash `82e002efbb67016379f7ead5d954ddc4e51809b6`, profile UUID `0d5e90ad-9dd5-42f5-9823-a6cfb5b01626`, and profile expiry 2027-08-05T02:36:17Z. CoreDevice installed and launched that exact app on Omega and reported 0.14.1 (56); the process remained present as PID 1176. See `2026-08-09-harcmobile-release-archive.md`. |
| App Store distribution export | Xcode's `app-store-connect` local export succeeded without upload. The 17 MiB IPA has SHA-256 `4ab371aaf2e5d00b9dfcc2b8beeeceda966fbaac67591889b14fe62e8c92fe2d`; its Apple Distribution-signed executable has SHA-256 `bec74d1914510a0f84a577b748b03bd7573dfb8624869558f819918a829d3b45` and CDHash `463fca0ae7c3ef3557efb060f45f79eba4bbdc24`. App Store profile `0df28cc6-72ff-4af1-a974-5c572dd490de` expires 2027-08-09T22:00:39Z, contains no devices or enterprise scope, and disables debugger attachment. |

## Immediate completion sequence

1. Capture the five screenshots from the exact release build.
2. Execute the physical qualification matrix with the declared oldest and
   current non-Pro hardware and preserve reports, hashes, logs, and visible
   outcomes.
3. Complete the secondary-Mac and remaining physical two-network/direct-route/
   visible-revocation evidence plus old-record/account-export expiry evidence.
4. Reconcile the validated distribution export with App Privacy/export
   answers, upload it, and
   inspect App Store processing warnings before submission.
