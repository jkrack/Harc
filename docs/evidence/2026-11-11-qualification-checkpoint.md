# November 11 qualification checkpoint

This is a source-scoped evidence update, not a release qualification. It preserves
the existing physical codec, protected-master, receipt, privacy and release gates.
The current candidate register retains its dated observations; this checkpoint
adds the latest hosted diagnostic result without relabeling those older passes.

## Candidate and hosted validation

[PR #192](https://github.com/jkrack/Harc/pull/192) remains draft at
`0ca0c4138c08b089ee78e93bb09b22be06b5be15`, stacked on #191, #190 and their
declared dependencies. [CI run 42903125913](https://github.com/jkrack/Harc/actions/runs/42903125913)
completed successfully. Its tested merge is
`9618fed4a4668f665517231835e672e3b03fa833`; do not describe the tested merge as
the branch head.

All five applicable jobs passed: build, macOS, mobile-configuration, relay and
mobile-diagnostics. Smoke was the configured PR skip. The package log records
1,903 Swift Testing cases in 312 suites, plus the separate XCTest and focused
regression stages. The listener-cancellation and blocking-I/O executor stages
passed, preserving the validation work originally merged in
[PR #106](https://github.com/jkrack/Harc/pull/106).
The Mac execution gate and embedded-helper verification both passed.

The mobile diagnostic identifies iPhone 17 Simulator, iOS 26.5 (23F77), with
90 test cases passed, zero failed and zero skipped. The retained console splits
these into 68 XCTest app cases, 14 Swift Testing cases and 8 UI cases.
The per-device summary counts 108 runs because six parameterized tests execute
24 runs; that is not 108 distinct test cases.

## Refresh-query observation

Downloaded mobile artifact `13806510108` matched the GitHub SHA-256:

`68279646a20f022faa0fd11a9c9edd3778a010397890a555024583ced3835256`

The console records one instrumented label read: it began 1,034 ms after the
expectation began, took 96 ms and returned the allowlisted `refresh_failed`
state. The expectation ended at 1,131 ms. The probe regression also passed.

This is a passing observation on the formerly failing hosted runtime. It does
not reproduce the earlier failure or prove its cause resolved. Instrumentation
can perturb scheduling. The unchanged predicate, timeout, direct final assertion
and navigation checks remain required; no alternative wait or retry is justified
by this result alone.

The source artifact is scheduled to expire on November 13 at 21:41 UTC.
Its ZIP was downloaded and digest-verified during this audit. No recording,
identifier-bearing live diagnostic or private application state was uploaded.

## Local preparation checks

The separate clean #192 checkout was used, leaving the unrelated dirty
production-hardening checkout unchanged. On November 11:

- Repository-side `scripts/preflight-harcmobile-app-store.sh` passed.
- All 18 `test_mobile*.py` tooling tests passed on the Mac mini.
- The source checkout remained clean.

These are source preparation checks. Public-URL, signed-archive,
distribution-app, screenshot and deployed privacy checks were not run.
An initial nonexistent test filename selected zero tests and is not counted.
Local re-export of the downloaded result summary was blocked by an xcresulttool
TestReport cache permission error; no permission setting was changed. Counts
above come from the successful hosted summary and digest-verified console.

## Release decision and next evidence

[Mac v0.14.20](https://github.com/jkrack/Harc/releases/tag/v0.14.20) remains the
latest published release. GitHub reports both DMG and ZIP assets uploaded.
Main's Sparkle entry remains 0.14.20 (75); its enclosure points to that DMG and
its 51,432,866-byte length matches release metadata. This audit did not
independently redownload or reverify the published DMG's signature/notarization.

The accumulated Dock, Library and Host-recovery improvements are useful release
candidates, but a green fixture stack does not qualify a new signed Mac artifact.
Select a clean integrated release source, perform its applicable capture,
Stop/save/playback/recovery acceptance and signed/notarized Sparkle artifact
checks before publication. Mac release qualification is separate from iPhone
qualification; App Store submission is not a Mac release requirement.

For the phone, follow the [physical qualification runbook](../operations/mobile-physical-qualification.md)
and [launch plan](../plans/2026-10-14-iphone-companion-launch.md):
bind one exact signed candidate to physical PCM/EOF codec evidence, an ordinary
phone capture, adopted-Host verified receipt and matching canonical PCM hash,
protected-master retention, and the Host-to-phone Library result. Do not enable
the codec from this Simulator result or promote user-observed TestFlight success
to formal physical release qualification. Exact-build privacy/account-owner,
archive/distribution and App Store gates remain open.

No merge, app installation/restart, live Host/data operation, codec-setting
change, credential change, release or App Store submission was performed.
