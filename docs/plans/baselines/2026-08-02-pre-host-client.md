# Pre-host/client implementation baseline

**Recorded:** 2026-08-02

**Commit:** `4a55f4a8ec448876215042b872aa2600fe210beb`

**Branch:** `main`

**Purpose:** Preserve the known starting state before host/client/mobile feature
code. This is evidence, not a green release claim.

## Toolchain

```text
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
Xcode 26.6 (17F113)
XcodeGen 2.45.4
```

## Results

### macOS application build

The existing Harc Xcode scheme built successfully in Debug for macOS. No host,
mobile, or placeholder module was compiled.

### Swift package tests

The complete package run executed 814 tests and reported six issues:

- one deterministic failure in
  `Tests/HarcCoreTests/VersionTests.swift`: `HarcVersion.fallbackVersion` is
  `0.9.1` while `project.yml` declares `MARKETING_VERSION: 0.11.4`;
- five load-sensitive timing failures from the full parallel run passed when
  rerun in isolation.

The deterministic version drift is the only confirmed current blocker to a
green baseline. PR 0 updates the fallback to the declared marketing version,
reruns the complete suite, and records any timing recurrence before feature
code begins. Timing failures are not waived merely because isolated reruns pass.

A focused `swift test --filter VersionTests` rerun on 2026-08-02 executed three
tests and reproduced exactly this one issue; the other two version tests passed.

### Dependency lockfile

Validation caused no retained change to `Package.resolved`. The planning-only
scaffold is not wired into `Package.swift` or `project.yml`.

## Required clean rerun for PR 0

```bash
git status --short
xcodegen generate
swift test
xcodebuild \
  -project Harc.xcodeproj \
  -scheme Harc \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Record total test count, all failures/retries, toolchain versions, commit, and
the final `Package.resolved` diff state. The feature baseline is accepted only
when the full run and Xcode build are green.

## PR 0 remediation evidence

**Branch:** `codex/host-client-mobile`

**Starting commit:** `4a55f4a8ec448876215042b872aa2600fe210beb`

The deterministic version drift was corrected by changing
`HarcVersion.fallbackVersion` from `0.9.1` to the declared marketing version,
`0.11.4`.

Validation on 2026-08-02 produced this sequence:

1. `xcodegen generate` completed successfully.
2. `swift test --filter VersionTests` passed all three tests in two suites.
3. The first complete `swift test` rerun reproduced load-sensitive timing
   failures in the documented queue/tray/keep-warm suites and one live-preview
   timing case. The implicated suites passed immediately in focused reruns; no
   production behavior was changed in response.
4. A subsequent complete `swift test` passed all 814 tests in 141 suites.
5. The unsigned Debug macOS `xcodebuild` completed successfully.

SwiftPM resolution removes the stale committed Sparkle pin from
`Package.resolved`. That is the repository's required everyday SwiftPM state;
the Xcode-only Sparkle dependency remains declared and version-constrained in
`project.yml`, and Xcode builds may temporarily add its pin as documented in
`AGENTS.md`.

This closes the green baseline gate for feature work. The failed full run and
focused reruns remain part of the evidence; they are not represented as a green
result.
