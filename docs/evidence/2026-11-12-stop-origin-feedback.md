# Stop feedback and recording-origin labels

## Scope

This is a presentation-only candidate stacked on the qualification-checkpoint
branch. It does not change microphone/system-audio shutdown, capture timestamps,
transcription finalization, publication, recovery, or the stop timeout.

- Record the first accepted Stop request as a presentation boundary. Elapsed
  displays freeze there while capture/resource ownership remains unchanged.
- Show `Finishing…` in the menu panel and live transcript instead of continuing
  to claim active recording. The card and island share the frozen duration and
  omit it once lifecycle timestamps clear during Library ingest.
- A queued Stop during preparation survives startup. Repeated Stop does not move
  its boundary; completion/error/reset paths clear it for the next recording.
- Resolve `This Mac` only from the exact existing Desktop Client capture identity.
  Preserve known remote names. Missing or blank labels become `Unknown device`,
  not an unsupported claim that the recording came from another computer.
- Standalone rows without an origin remain unlabelled. Historical identities are
  not inferred from paths or current device role.

The frozen display is the Stop-request duration, not a replacement for actual
capture timestamps or final recorded-audio duration.

## Validation

- Final focused package run: 39 tests in 8 suites passed, zero skips.
- Covered recording state, stop presentation, elapsed formatting, bridge state,
  menu version presentation, origin labels, Library refresh and navigation.
- Includes the handoff where recording timestamps clear but the bridge remains
  in its finishing state; no spurious `0:00` is shown.
- Independent source review found no remaining blocking issue.
- Isolated Debug Xcode app build passed, including embedded daemon and MCP
  helpers. A final incremental build against the final source also passed.
  The diagnostic app was neither launched nor installed; this is compilation
  evidence, not UI execution or release qualification.

## Limits

No live recording, recording-content access, installed-app launch/restart,
installation, data mutation, merge, or release was performed. No live UI or
physical-device qualification was run. The full package and hosted CI gates are
not replaced by these focused tests. Recording-time sluggishness and the older
long-finalization hang in issue #105 remain unmeasured and unresolved by this
presentation change.
