# HarcMobileSpikes

This directory is reserved for the non-shipping, signed iOS 26 physical-device
harness used to decide the lossless codec before host ingest and to validate
background TLS/gRPC behavior before the production mobile transport freezes.

It becomes an Xcode target only in PR 3, is never distributed, and is folded
into or removed by PR 7. Spike results are recorded as dated evidence; spike
code does not silently become product code without the production tests and
boundaries in the implementation specification.

The PR 3 harness offers two deliberately different runs:

- **Quick comparison** accelerates five 60-second canonical chunks through both
  CAF+ALAC and FLAC. It catches unsupported encoders, corruption, and obvious
  performance problems, but never qualifies a release decision.
- **Three-hour real-time characterization** evaluates one candidate at ordinary
  60-second
  production boundaries and records bit-exact hashes, p95 latency, queue depth,
  incremental resident memory, output size, and thermal state for all 180
  chunks. The first chunk becomes ready only after the first full minute, so a
  qualifying report must record at least 10,800 seconds of monotonic elapsed
  time. Resident high-water memory and thermal state are observed throughout
  the run, not just at chunk endpoints. Its JSON report is the evidence artifact
  retained for endurance and performance evidence.

Build physical evidence with the exact commit and signing team embedded, for
example by passing `HARC_BUILD_SHA=<40-hex-commit>` and
`DEVELOPMENT_TEAM=<10-character-team-id>` as Xcode build settings. A report
containing `unrecorded`, a simulator model, a quick mode, failures, or incomplete
chunks is not eligible to freeze the release codec. Memory and thermal
measurements must also remain available for the complete run; an unavailable
Mach measurement or an unknown thermal state is explicitly nonqualifying rather
than a zero/nominal result.

Schema 5 records a unique report ID and process-launch ID together with the
sealed bundle identifier, version/build, signing-team identifier, source commit,
whether the process is an iOS app running on macOS, and the current
user-interface idiom. A qualifying device must be a phone with an `iPhoneN,M`
hardware identifier; Simulator, Catalyst, Designed-for-iPhone on Mac, unsigned
or unidentified builds, and reused app processes fail closed.

Each qualifying report proves only one candidate on the recorded physical
device. It does not create a required marketing-model role. The shipping codec
is enabled only after the selected codec passes a focused physical bit-exact
regression and one real phone-to-Host product-path transfer returns a verified
durable receipt with matching canonical PCM hashes and no local-master cleanup
before receipt. Three-hour reports provide additional endurance evidence.
Fully quit and relaunch the harness between candidates; the host-side validator
rejects a process-launch ID reused by two matrix cells.

For unattended simulator diagnostics, launch with
`--run-quick-codec-spike`. A physical three-hour characterization can be started
with
`--run-three-hour-alac-spike` or `--run-three-hour-flac-spike`; the same
acceptance rules apply regardless of whether the button or launch argument
started the run.

When comparing two devices and both codec candidates, validate the optional
four-report diagnostic matrix on the Mac with:

```bash
swift run harcctl qualify-codec-matrix \
  --oldest-device iPhoneN,M \
  --current-device iPhoneN,M \
  --build-sha <40-hex-commit> \
  --team-id <10-character-team-id> \
  --version <marketing-version> \
  --build <build-number> \
  --oldest-alac <oldest-alac.json> \
  --oldest-flac <oldest-flac.json> \
  --current-alac <current-alac.json> \
  --current-flac <current-flac.json>
```

Passing means both candidates satisfy the frozen thresholds on those two
recorded devices. It does not establish required device roles, choose the
release codec, or enable the production compile-time gate; that remains a
reviewed decision backed by the physical product-path evidence above.

Recorded evidence:

- [2026-08-02 simulator diagnostic](../docs/evidence/2026-08-02-codec-spike-simulator-diagnostic.md)
