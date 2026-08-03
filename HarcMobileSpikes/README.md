# HarcMobileSpikes

This directory is reserved for the non-shipping, signed iOS 18 physical-device
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
- **Three-hour real-time gate** evaluates one candidate at ordinary 60-second
  production boundaries and records bit-exact hashes, p95 latency, queue depth,
  incremental resident memory, output size, and thermal state for all 180
  chunks. The first chunk becomes ready only after the first full minute, so a
  qualifying report must record at least 10,800 seconds of monotonic elapsed
  time. Resident high-water memory and thermal state are observed throughout
  the run, not just at chunk endpoints. Its JSON report is the evidence artifact
  required by the spec.

Build physical evidence with the exact commit embedded, for example by passing
`HARC_BUILD_SHA=<40-hex-commit>` as an Xcode build setting. A report containing
`unrecorded`, a simulator model, a quick mode, failures, or incomplete chunks is
not eligible to freeze the release codec. Memory and thermal measurements must
also remain available for the complete run; an unavailable Mach measurement or
an unknown thermal state is explicitly nonqualifying rather than a zero/nominal
result.

Schema 4 also records whether the process is an iOS app running on macOS and
the current user-interface idiom. A qualifying device must be a phone with an
`iPhoneN,M` hardware identifier; Simulator, Catalyst, and Designed-for-iPhone
on Mac runs fail closed.

Each qualifying report proves only one candidate on one named device. Freeze
the release codec only after fresh-process, three-hour reports exist for both
candidates on the named oldest-supported and current iPhones.

For unattended simulator diagnostics, launch with
`--run-quick-codec-spike`. The physical gate can be started with
`--run-three-hour-alac-spike` or `--run-three-hour-flac-spike`; the same
acceptance rules apply regardless of whether the button or launch argument
started the run.

Recorded evidence:

- [2026-08-02 simulator diagnostic](../docs/evidence/2026-08-02-codec-spike-simulator-diagnostic.md)
