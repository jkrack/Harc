# iPhone 15 Pro Max CAF + ALAC three-hour thermal failure

Date: 2026-08-04

This physical-device run completed the full real-time workload, but it does not
qualify because the phone reported a serious thermal state. Retain it as failed
gate evidence; do not use it in the four-cell release matrix.

## Sealed build and device

- Source commit: `7010498f4b55c8f7f67231a377f81d8e73118f05`
- Signing team: `63TNU5M7P4`
- Bundle: `com.harc.HarcMobileSpikes`
- Version/build: `0.13.0 (45)`
- Device: Omega, iPhone 15 Pro Max (`iPhone16,2`)
- OS: iOS 26.0 (`23A340`)
- Interface: phone; physical iOS device; not Simulator or iOS-on-Mac
- Candidate: CAF + ALAC
- Report UUID: `55612C8B-CC0A-4636-88F5-B8198DCC4F22`
- Process launch UUID: `C0E8109A-74C7-483B-A30A-307F9920D0A1`
- Raw report: [`2026-08-04-omega-caf-alac-three-hour-thermal-fail.json`](2026-08-04-omega-caf-alac-three-hour-thermal-fail.json)

## Results

- Real-time duration: 10,800.275 seconds
- Chunks: 180/180 completed; 0 failed
- Bit-exact: yes for every decoded PCM hash
- p95 encoding: 29.551 ms
- Maximum encoding: 418.001 ms
- Maximum queue depth: 1
- Maximum incremental resident memory: 13,697,024 bytes
- Total encoded bytes: 307,643,089
- Memory measurements: available for every trial
- Thermal measurements: available for every trial
- Serious or critical thermal observed: **yes — gate failure**

The serious state was recorded at zero-based chunk indices 5 through 10 and 15
through 19. No critical state, encoding failure, hash mismatch, queue overflow,
latency failure, or memory failure was recorded.

## Decision

This report fails the frozen rule that no serious or critical thermal state may
occur. The remaining performance and integrity thresholds passed, but they do
not override the thermal failure.

Allow Omega to return to a cool nominal or fair state before a new fresh-process
CAF + ALAC run. Do not start the FLAC matrix cell immediately after this failed
run. The rerun must use the same sealed build identity unless source changes are
required, and its report and process-launch UUIDs must be new.
