# Mobile Physical Qualification

This runbook collects the physical evidence required before Harc can enable a
shipping mobile lossless codec or claim the local-network iPhone alpha complete.
Simulator, Catalyst, and iOS-app-on-Mac results are diagnostic only.

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

## Codec matrix prerequisites

### Recommended oldest-device target

With the current iOS 18 deployment floor, use a physical **iPhone XR on an iOS
18 release** as the oldest-device qualification target unless the launch floor
changes before the archive is frozen. [Apple includes iPhone XR, iPhone XS, and
iPhone XS Max in the iOS 18 compatibility set](https://support.apple.com/en-us/104985);
choosing XR exercises an actual oldest eligible model rather than inferring
support from a newer phone.

This recommendation is about capture, protected storage, lossless encoding,
background transfer, and UI reliability. Shipping HarcMobile inference remains
Host-backed, so optional future on-device inference does not justify excluding
an otherwise capable capture client. The recommendation is not passing
evidence: the named physical XR/OS still has to complete the codec and scenario
matrix below. Do not add an unrelated required-device capability merely to hide
the missing run.

### Required current non-Pro target

The specification separately requires a current non-Pro iPhone on the current
iOS release so high-end Pro hardware cannot hide queue, memory, thermal, or
layout failures. For this qualification cycle, use a physical **iPhone 17** on
the current iOS release. Apple identifies iPhone 17 as the current standard
model introduced in 2025; record its exact `iPhoneN,M` identifier and OS build
at test time. Omega, an iPhone 15 Pro Max, remains valuable additional physical
evidence but does not satisfy this named matrix role.

[Apple iPhone 17 technical specifications](https://support.apple.com/en-us/125089)

- One named oldest-supported iPhone/OS and one named current non-Pro
  iPhone/current OS.
- Both exact `iPhoneN,M` hardware identifiers recorded before the run.
- One clean source commit used for every matrix cell.
- A signed `HarcMobileSpikes` build with the exact 40-character source commit and
  10-character Apple team ID embedded in its sealed Info.plist.
- Enough uninterrupted time for four real-time three-hour runs.

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

The exported schema-5 report must show the expected bundle ID, version/build,
team ID, source commit, physical hardware identifier, phone idiom, and a unique
report/process-launch pair. A blank or `unrecorded` value cannot qualify.

## Four fresh-process runs

Run both candidates on both devices:

| Matrix cell | Launch argument |
| --- | --- |
| Oldest iPhone, CAF+ALAC | `--run-three-hour-alac-spike` |
| Oldest iPhone, FLAC | `--run-three-hour-flac-spike` |
| Current iPhone, CAF+ALAC | `--run-three-hour-alac-spike` |
| Current iPhone, FLAC | `--run-three-hour-flac-spike` |

For every cell:

1. Fully terminate `HarcMobileSpikes` before launching the candidate.
2. Keep the phone on its named OS and ordinary thermal environment; do not use
   Simulator acceleration.
3. Leave the harness in the foreground and do not manually lock the phone. The
   harness disables the idle timer only while a run is active; keep the phone
   connected to power for the full gate.
4. Let all 180 ordinary 60-second chunks complete in real time.
5. Export the JSON report immediately and name it for the device and codec.
6. Confirm the app is terminated before starting the other candidate.

The process-launch UUID is generated once per app process. Reusing one process
for two cells causes the matrix validator to fail even if every codec metric is
otherwise green.

## Validate the matrix

Run the validator from the same clean source checkout:

```bash
swift run harcctl qualify-codec-matrix \
  --oldest-device <iPhoneN,M> \
  --current-device <iPhoneN,M> \
  --build-sha <40-hex-commit> \
  --team-id <10-character-team-id> \
  --version <marketing-version> \
  --build <build-number> \
  --oldest-alac <oldest-alac.json> \
  --oldest-flac <oldest-flac.json> \
  --current-alac <current-alac.json> \
  --current-flac <current-flac.json>
```

The validator independently recomputes ordered trial coverage, bit-exact hash
agreement, p95/max encoding time, and encoded-byte totals. It validates queue
depth, memory, and per-trial thermal evidence against the frozen thresholds. It
also proves that the four cells use distinct report and process-launch IDs and
one exact sealed build identity.

A passing matrix means both candidates meet the frozen safety thresholds on
both devices. It does not automatically select or enable a codec. Retain the
four reports, record the reviewed size/performance decision in `docs/evidence/`,
and only then add the chosen production compilation condition to `project.yml`.
Never enable `HARC_MOBILE_QUALIFIED_CAF_ALAC` from Simulator evidence.

## Remaining iPhone matrix

After the codec decision, execute Section 25.2 of the implementation
specification: C1-C7, T1-T7, T2b-T2e, P1, and H1. C1, C2, T1, and T2 require
three consecutive passes on both named iPhones. Every host-committed WAV must
match the phone's complete canonical PCM SHA-256; no run may create a duplicate,
delete the final client copy before a verified receipt, or hide a lost interval.

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

On 2026-08-09, Omega (`iPhone16,2`, iOS 26.6) passed an additional physical C7
diagnostic. The isolated copied state proved a playable durable prefix, matching
canonical PCM hash, `storageExhausted` metadata, explicit discontinuities, and
no premature receipt or cleanup. See
`docs/evidence/2026-08-09-omega-c7-storage-exhaustion.md`. The oldest-device and
exact sealed-build repetitions remain open.

The same device also passed one deterministic C5 force-quit/relaunch diagnostic.
The UI visibly recovered one durable recording, and isolated state inspection
proved one playable, hash-matching `recoveredDurablePrefix` without a receipt or
cleanup intent. See
`docs/evidence/2026-08-09-omega-c5-force-quit-recovery.md`. Randomized timing,
oldest-device, and exact sealed-build repetitions remain open.

The complete signed Omega regression also passed a native XCTest
accessibility audit with no ignored findings on the Record, offline Review
Sample, and Privacy surfaces. That automated result does not replace the
manual VoiceOver and physical largest-text traversal required by this runbook,
and Omega does not replace either the oldest-device or current non-Pro matrix
device.

## Manual accessibility closeout on each named phone

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
or archive change. A pass on Omega is useful extra evidence but does not close
the two named-device requirement.
