# Mobile empty local recordings and navigation investigation

Date: October 16, 2026 (Pacific). Reviewed application/test candidate:
`3a975fea5fc1fe886a3ecf8e530f34eec913913e`.

## Recorded failure and causal limits

[CI 38994439263](https://github.com/jkrack/Harc/actions/runs/38994439263)
failed the original `testSyncDetailsAreDiscoverableWithoutHostOrRecording`
at line 71 while waiting for `harc.mobile.host.sync-status`. The Mac/package
checks passed. The mobile result was 69/70 logical tests, with one failed case.
The exact merge checkout had the same source tree as `1886423`.

The first anomaly preceded the Host tap: after opening local recordings, XCTest
reported that the app event-loop idle notification was not received. The saved
hierarchy later showed Library selected, “On This iPhone” visible, and an empty
zero-width scroll view. The only Host tab button had frame `(240,795,94,54)`.
The original synthesized event targets the same application PID and sends its
down/up events to `(287,822)`, exactly that frame's center. Wrong coordinates or
duplicate Host targets are unsupported by this evidence. Correct synthesis does
not prove UIKit processed the event.

Source inspection found no asynchronous assignment back to Library. Bootstrap
constructs the transfer/pairing coordinators before publishing ready state.
Neither fact establishes the precise cause of the recorded dropped tap.

**The Host failure has not been established as an empty-layout defect.** The
unchanged baseline passed all planned repetitions while still rendering zero
width. The initial red result remains evidence; passing samples do not erase it
or justify declaring a simulator flake. The event-loop stall and Host selection
remain a bounded readiness/race investigation, without a proved platform cause.

## Demonstrated application defect and scoped change

The Sync destination previously supplied a `ScrollView` whose only child emitted
nothing when there were no local recordings and no error. Both Library and Host
can reach this blank “On This iPhone” screen through Sync.

The destination now supplies explicit empty/unavailable content and full-width
layout. Nonempty/error cases keep the same row renderer and actions. Navigation
title modes, tab-selection code and the pending-recordings sheet are unchanged.
No capture, transfer authority, retry policy, codec gate, identity/signature,
signing, credential or dependency changes are included.

## Controlled runtime evidence

All completed runs below used iPhone 17 **Simulator**, iOS 26.5 (23F77), arm64,
built on macOS 26.6.2. Each diagnostic uses three planned iterations, without
retry-on-failure, retry taps, sleeps or disabled animations. Every outcome is
retained in its result bundle.

- [Unchanged application baseline 38999584217](https://github.com/jkrack/Harc/actions/runs/38999584217),
  commit `fb851350a1f81c8d4785c6c303075a9a113976b0`: four tests / 12 executions
  passed. The original failing method plus Library-root, Sync-only and nested
  local-recordings routes all passed. Nested scroll width was **0** in all three
  measured runs; the single Host button was hittable and selected successfully.
- [Application candidate 39000064246](https://github.com/jkrack/Harc/actions/runs/39000064246),
  commit `3a975fea5fc1fe886a3ecf8e530f34eec913913e`: five tests / 15 executions
  passed. The common four tests passed in all iterations. The added regression
  performs three navigation cycles per iteration, for **nine cycles**, preserving
  separate Library/Host stacks while switching through Record without starting
  capture. Nested scroll width was **402** in all three measured runs; the
  regression also requires visible empty content and positive destination width.

The full original mobile configuration context is a separate matched comparison:
[baseline 39001233129](https://github.com/jkrack/Harc/actions/runs/39001233129)
at `faeb3d1ab9700f62ef1d05b78c5c6e4a1620b922`, and
[candidate 39001313037](https://github.com/jkrack/Harc/actions/runs/39001313037)
at `cd5fafb2e3c3c1bb7d51845319ff0a22a899a5d1`. These commits differ **only**
in `HarcMobileRootView.swift`. Both use the same original app-test prelude and
original two UI-test selections, repeated three times. They avoid attributing an
effect of the added tests/order to the application change. The baseline passed
all 70 logical tests / 261 executions. The root-only candidate passed 69/70
logical tests / 260 of 261 executions: the first original Sync test failed at
line 48 in `app.launch()` while XCTest tried to terminate the preceding app
process. No navigation executed in that failed repetition; the other two
repetitions passed. This is distinct from the original Host-tap observation.
The failed result is retained, without retrying it.

## Explicit UI-test process cleanup

The test app factory now registers teardown for its owned application: one
termination attempt, followed by one ten-second wait for `.notRunning` and an
assertion. It prints the final process state, and a failed cleanup remains a
test failure. There are no launch retries, extra taps or relaxed assertions.
The state wait does not bound `terminate()` itself, whose duration XCTest
controls; the existing outer runner deadline remains in force.

This is lifecycle hardening, not a proved fix for the simulator failure.
`launch()` already has a contract to terminate a running application, so the
preceding app remaining alive is not itself proof of an invalid test harness.
The isolated control branch changes only this cleanup relative to `cd5fafb` and
retains the original app-test selections, two UI methods and three planned
iterations. Its outcome and the final PR's exact-head CI must be evaluated
before describing this cleanup as verified. The original Host-drop mechanism
remains unproved even if these new samples pass.

## Regression and source preservation

The original failing test method is byte-for-byte unchanged from `1886423`;
its body SHA-256 is
`d0f494585bec590a6e6b4a6a978b8b2136978e505a78ff57ee4c2a440aa9edd3`.
New controls require a unique native Host tab, one tap and successful selection.
The repeated-flow helper waits boundedly for existence/hittability before its
single tap. All four added tests are selected by normal mobile configuration CI.

Application root hashes:

- Baseline: `b7fefa2f6d34e5da995a481340ff02d8fd7dfaa995f2ff426b7de2d2654f4819`.
- Candidate: `803127ebda4e175e20cbb2c4709fc0135c3df0e75d4254fe7c22bfd47658a24f`.

Independent read-only review at `3a975fea` found no actionable source defect and
confirmed the preserved behavior, original test and normal-CI selections.
Swift parsing, shell syntax and diff checks pass. The entire UI-test file also
typechecks in Swift 6 against the installed Xcode 27 simulator SDK with the
XCTest overlay; this is compilation evidence, not runtime qualification.

Original diagnostics remain under
`/Volumes/MacMiniSDD/HarcBuilds/p256-equivalent-form-20261016/evidence/ci-38994439263`.
New run JSON, checksummed ZIPs, result bundles, test trees, logs, original tap
archive and source-review/typecheck receipts are retained under
`/Volumes/MacMiniSDD/HarcBuilds/mobile-host-navigation-evidence-20261016`.
The historical diagnostic workflow is retrievable from the two diagnostic commits;
it is removed from the final UI diff.

## Remaining qualification

Use the final PR's exact-head terminal CI before assessing the combined source
tree. This UI change is separate from cryptographic PR #124 and does not close
its broader OS, physical identity, signed integration or release gates. These
simulator checks do not qualify a physical iPhone, microphone capture, codec
transfers or a release. No Mac/physical-device installation, recording, merge,
gate enablement or release is part of this investigation.
