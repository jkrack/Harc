# Combined release CI: Mac fixture path identity

## Retained failure and verified state

PR #207 head `53118b83189b8f6668e798d90366c71d02981121`, CI run
[43799606474](https://github.com/jkrack/Harc/actions/runs/43799606474), failed the
Mac app/UI execution step after its build passed. The tested merge
`f2bc6cb1712a4b642f62956b432f09c6a7241e64` has the same Git tree as the PR head.
The sealed result reports 120 test methods: 119 passed, one failed, none skipped.
The UI bundle executed 16 cases, with the single failure in
`HarcAppUITests/testBoundSpeakerCreateUnassignAndRelinkSurviveRelaunch` at line 484.
The subsequent execution and helper checks did not run; this is not a green gate.

The retained `macos-validation` artifact 14198435266 was verified against its
published SHA-256 digest:
`9e7f0159a774015e40588016ae2ef9a4db99239b06733f3a129b4f8209226d89`.
Its original result bundle, logs, source/toolchain metadata, and failed-case
attachments remain on the SSD. The runner used Xcode 26.6 (17F113) on macOS
26.7.2 (25G332), arm64 Apple Virtual Machine 1.

## Observed cause

The initial test selected `harc.library.recording.1`, created a person, and
successfully observed the assignment before termination. The video after
relaunch shows that same original recording displaying the newly assigned
person in its transcript. The assignment persisted.

A second row, titled `Amy, Jason`, also appeared. At 20.39 seconds the generic
`seededRecordingRow()` helper selected `harc.library.recording.2`, because it
matches the first element with the recording identifier prefix. The test then
checked that other row's unassigned picker for the first row's person.

The fixture root introduced in `025a03b` used `/tmp`. An independent read-only
Foundation probe confirmed that `contentsOfDirectory` enumerates that symlink's
children with `/private/tmp` spelling. The fixture stores the `/tmp` WAV path,
while startup `RecordingIngestor` checks exact `wavPath` equality against the
enumerated `/private/tmp` path. It therefore imports the same synthetic audio as
another row before the fixture seeder sees the already-populated store.

## Scoped test correction

The UI fixture now uses canonical `/private/tmp` spelling while retaining its
fresh UUID, shared scratch isolation and target-owned creation. The bound-speaker
case additionally deduplicates inherited accessibility row identifiers and
requires exactly one recording. It captures that recording's identifier and
requires the same one after relaunch, before checking person persistence.

No assignment, unassignment, relink, timeout or failure assertion is removed or
relaxed. Selecting the old row while ignoring a duplicate is deliberately not
accepted. No production speaker, ingestion or canonical identity logic changes.
Focused runtime validation and fresh exact-source CI are still required.

## Separate product follow-up

Legacy filesystem ingestion can confuse alternate symlink spellings of the same
WAV with different recordings because its lookup is path-string based. This
broader behavior predates the new fixture path and should receive an
identity-safe ingestion regression and fix separately. It must not be addressed
by weakening Host canonical namespace reservations, signed receipt binding,
protected-master validation or local moved-library recovery approvals. This
record tracks the issue; it does not claim the product behavior is fixed or
that a public issue has been opened.

No merge, notarization, new TestFlight upload or Sparkle publication occurred as
part of this investigation. Existing artifacts retain their original source
identity and cannot be silently relabeled for the amended candidate.

## Local diagnostic qualification status

The amended isolated build-for-testing passed after expressing the new identifier
mapping as an actor-context closure rather than an actor-isolated key path. The
initial focused runtime attempt failed during XCTest automation initialization,
with zero qualified cases. After owner authentication, a controlled no-build retry
started a test but the target stalled in the dynamic loader before app code.
Retained access-preflight logs report a code-requirement mismatch for the rebuilt
runner's removable-volume access; no final permission-denial decision was captured,
so this is a leading explanation, not proof of the sole cause.

Owned test processes were stopped and all failure evidence retained. No permissions
were changed and no UI case is claimed passed. Focused Mac runtime qualification,
new exact-source CI, and source-bound artifacts remain required.
