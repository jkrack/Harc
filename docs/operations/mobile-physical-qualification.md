# Mobile Physical Qualification

This runbook collects the physical evidence required before Harc can enable a
shipping mobile lossless codec or claim the local-network iPhone alpha complete.
Simulator, Catalyst, and iOS-app-on-Mac results are diagnostic only.

## Codec matrix prerequisites

- One named oldest-supported iPhone/OS and one named current iPhone/current OS.
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
