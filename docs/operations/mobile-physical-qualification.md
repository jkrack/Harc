# Mobile Physical Qualification

This runbook collects the physical evidence required before Harc can enable a
shipping mobile lossless codec or claim the local-network iPhone alpha complete.
Simulator, Catalyst, and iOS-app-on-Mac results are diagnostic only. Harc does
not require an iPhone SE (2nd generation), an iPhone 17, or any other named
marketing model to enable the codec or complete the iPhone release gate.

## Short product-path checkpoint

Before beginning long physical scenarios, make one ordinary recording in the
installed HarcMobile app and wait for **Saved locally**. Copy and summarize the
phone state without XCTest:

```bash
./scripts/audit-mobile-state.sh <device-name-or-identifier>
```

The script refuses to overwrite an explicitly named output directory, copies
only HarcMobile's Application Support state, opens the copied SQLite databases
read-only, and reports nonsecret capture, outbox, upload, receipt, conflict,
cache, and live Host-ingest counts. Retain the printed snapshot path until the
checkpoint evidence is recorded.

This is a content/state audit only. Copying files to macOS does not preserve
evidence of their original iOS Data Protection class or backup-exclusion
metadata, so the script cannot satisfy the physical protection gate.

## Codec qualification prerequisites

Use one available physical iPhone within the declared iOS release scope. Record
its exact `iPhoneN,M` hardware identifier and OS build rather than inferring
behavior from a Simulator. Compact, older, current non-Pro, and additional Pro
phones provide useful compatibility coverage, but they are not named release
roles and do not block codec enablement.

The selected shipping codec qualifies when one exact candidate build proves all
of the following on the recorded physical phone:

- bit-exact encode/decode for canonical PCM, including exact-end-of-file
  behavior;
- a real app capture reaches the adopted Host through the production transfer
  path and returns a verified durable receipt;
- the Host's canonical decoded PCM SHA-256 matches the phone's complete
  canonical PCM SHA-256; and
- the phone retains its protected local master until that receipt is verified.

The three-hour spike harness remains available for performance, memory, queue,
and thermal characterization. It is recommended before a broad public release,
but a four-cell comparison across two named phone models is not a codec release
gate.

- One physical iPhone and its exact hardware/OS identity.
- One clean source commit used for the app, Host, and focused regression.
- A signed HarcMobile build with the exact 40-character source commit and
  10-character Apple team ID embedded in its sealed Info.plist.
- A reachable adopted Host built from the recorded source.

Generate the project, record the clean commit, and build with two workers. Supply
the physical device destination and signing team appropriate to the development
Mac:

```bash
xcodegen generate
git rev-parse HEAD
xcodebuild \
  -project Harc.xcodeproj \
  -scheme HarcMobileSpikes \
  -configuration Debug \
  -destination 'id=<physical-device-udid>' \
  -jobs 2 \
  HARC_BUILD_SHA=<40-hex-commit> \
  DEVELOPMENT_TEAM=<10-character-team-id> \
  SWIFT_MAXIMUM_CONCURRENT_COMPILE_TASKS=2 \
  build
```

The physical evidence record must show the expected bundle ID, version/build,
team ID, source commit, physical hardware identifier, phone idiom, focused test
result, capture/upload/receipt identities, and matching canonical hashes. A
blank or `unrecorded` value cannot qualify. Never enable
`HARC_MOBILE_QUALIFIED_CAF_ALAC` from Simulator evidence.

## Remaining iPhone qualification

After the codec decision, execute Section 25.2 of the implementation
specification: C1, C3-C7, T1-T7, T2b-T2e, P1, and H1. C2 is optional
endurance evidence. C1, T1, and T2 require
three consecutive passes on the recorded physical qualification iPhone. Every
host-committed WAV must match the phone's complete canonical PCM SHA-256; no run
may create a duplicate, delete the final client copy before a verified receipt,
or hide a lost interval.

The Debug HarcMobile app supports the C7 deterministic quota argument documented
in the release-gate audit. No other manual result should be promoted to passing
without device/OS/build identity, timestamps, logs, hashes, and the expected
visible UI outcome.

The checked-in UI qualification harness uses canonical, per-test UUID roots.
Its Debug-only reset argument is valid only with exactly one such UUID, removes
only that constructed test root before the first launch, and is ignored by
Release builds. Preserve the root across relaunch for interruption scenarios
such as C5. This keeps repeated C5/C7 diagnostics independent without granting
the harness a path to ordinary application storage.

Run the complete UI bundle through the provenance wrapper instead of an ad-hoc
`xcodebuild` invocation:

```bash
./scripts/qualify-harcmobile-ui.sh \
  --destination-id <physical-device-udid> \
  --platform physical \
  --development-team <10-character-team-id> \
  --derived-data-path <new-derived-data-directory> \
  --output-dir build/qualification/<unique-run-name>
```

The wrapper refuses to overwrite evidence, enforces two workers and requires
8 GiB of starting headroom to preserve the 5 GiB operational floor, requires a
clean tree for release evidence, and retains the
source-file manifest/fingerprint, source status, destination details, build
log, test summary, and a SHA-256-stamped zipped result bundle. The explicit
`--derived-data-path` option requires a new directory, records it in the
qualification receipt, and allows disposable compiler artifacts to live on a
separate high-capacity volume without moving Harc recordings or user data.
The explicit `--allow-dirty-diagnostic` escape hatch labels current-tree engineering runs;
it is never release evidence. Simulator runs use `--platform simulator` and
remain diagnostic only. Physical runs make up to three bounded launch attempts
by default because CoreDevice can time out while enabling automation before a
Harc test method executes. Every attempt is retained. `xcresulttool` represents
that runner bootstrap error as one failed pseudo-test, so the wrapper recognizes
it only when every reported failure is the HarcMobile UI runner's exact
automation-mode timeout. A zero-test or runner-only result never passes; only
an attempt with executed Harc tests, zero failures, and a successful
`xcodebuild` status is selected. Signing, compilation, real test, and other
deterministic failures stop immediately. Physical runs require the explicit
Apple team ID used to sign the candidate. The wrapper embeds the recorded
source commit in the Debug app. Use `--attempts 1` to diagnose the first-launch
failure itself, not to weaken the release gate.

On 2026-08-09, Omega (`iPhone16,2`, iOS 26.6) passed an additional physical C7
diagnostic. The isolated copied state proved a playable durable prefix, matching
canonical PCM hash, `storageExhausted` metadata, explicit discontinuities, and
no premature receipt or cleanup. See
`docs/evidence/2026-08-09-omega-c7-storage-exhaustion.md`. Exact sealed-build
repetitions remain open.

The same device also passed one deterministic C5 force-quit/relaunch diagnostic.
The UI visibly recovered one durable recording, and isolated state inspection
proved one playable, hash-matching `recoveredDurablePrefix` without a receipt or
cleanup intent. See
`docs/evidence/2026-08-09-omega-c5-force-quit-recovery.md`. Randomized timing,
exact sealed-build repetitions remain open.

The complete signed Omega regression also passed a native XCTest
accessibility audit with no ignored findings on the Record, offline Review
Sample, and Privacy surfaces. That automated result does not replace the
manual VoiceOver and physical largest-text traversal required by this runbook,
and does not replace manual VoiceOver or largest-text verification.

## Manual accessibility closeout on the qualification phone

Run this from the exact candidate build with the device/build identity recorded.
Do not promote the automated audit or simulator Dynamic Type run as a substitute.

1. Set **Settings > Accessibility > Display & Text Size > Larger Text** to the
   largest available size, launch Harc, and confirm Record, Library, Host,
   Offline Review Sample, and Privacy & Data remain reachable without clipped
   controls or an impossible scroll path.
2. Enable VoiceOver. Starting from a fresh launch, traverse the three tabs in
   swipe order. Every actionable element must announce a meaningful label,
   role, state, and hint where needed; focus must not become trapped or jump
   behind a presented sheet.
3. On Record, start a short real capture, confirm the persistent recording
   state and Stop control are announced, stop it, and confirm **Saved locally**
   is announced without implying Host receipt.
4. In Library, open the offline review sample, play and stop the synthetic
   audio, traverse status/summary/transcript/metadata, open Privacy & Data, and
   close the sample. Confirm every control is reachable and the reading order
   follows the visual hierarchy.
5. On Host, reach Privacy & Data and verify the adopted-Host/optional-relay
   disclosure is readable without pairing, permissions, or network access.
6. Record pass/fail per screen, the first failing element and exact spoken text,
   screenshots or video where useful, tester name, timestamp, device model and
   `iPhoneN,M`, OS version/build, app version/build, and source/archive identity.

Repeat after any material layout, accessibility-label, release-configuration,
or archive change. Record any additional-device runs as compatibility evidence,
not as prerequisites invented after the candidate is ready.
