# Library selection latency investigation

The owner reported an intermittent pause of the entire Library when switching recordings. The running installed app was `/Applications/Harc.app`, 0.14.19 (74), source `18ea1a11244acc87555ecc6a01348caf45114698`. The same loading pattern exists in 0.14.20 and current main. This investigation starts at `ed832934032f704a7014a584e8186e77b5b152da` and uses an isolated `codex/library-selection-latency` branch.

## Blocking work found in source

- The selection-change handler synchronously loads transcript text and JSON, renders generated text and builds the word index on the UI actor.
- `speakerIndices(for:)` reads and decodes the JSON and projects every word into speaker turns during view rendering. The conditions row and speaker summary both call it; opening the inspector adds more calls. These reads repeat when unrelated state invalidates the view.
- The old `transcriptSegments` state is populated twice from JSON, including after speaker-name resolution, although the current NSTextView editor never reads it.
- Unstructured envelope tasks can finish after selection changes and assign the old recording's waveform.

These are confirmed blocking paths. They explain why transcript size and filesystem latency can affect responsiveness. The exact pause in the owner's Library has not been instrumented or reproduced against private recordings.

## Change

A selection-bound task prepares a `RecordingDetailSnapshot` off the UI actor. It retains the decoded document and the existing export speaker projection, so view rendering and label updates use memory instead of reopening JSON. Superseded and cancelled loads cannot publish results, including A -> B -> A. Envelope and inspector results also check their recording before publication.

Source changes invalidate the snapshot; title and summary edits alone do not. Transcript edits made during a background read prevent that read from replacing the editor. Existing overlap projection, manual-edit preservation, autosave and word timings are retained. Generated-text matching short-circuits the common joined-text match. The unused display-segment path is removed.

The DEBUG `selection-latency` fixture contains a 42-minute synthetic recording with 32,000 words and 4,000 speaker turns, plus a short neighbor. Its UI regression repeatedly selects the long recording and then the short one and checks that the short transcript remains selected. No real recording data is used.

## Validation status

- Mac diagnostic `build-for-testing` passed after correcting development compile errors. The final build took 55 seconds. It uses a separate `com.harc.Harc.LibraryLatency` bundle identity and was built from the working diff on the base above.
- Seven new focused regressions cover background read placement, rapid reselection, cancellation, overlap/manual text preservation, missing sidecars, long-transcript metadata reuse, and source invalidation. They are shared with the Mac app test target. A long-transcript case prints comparative lookup measurements; no performance numbers are claimed before execution.
- Two local app/UI launch attempts stalled before any test case started and were stopped. The second used verified internal runtime copies with fixtures/results on the SSD. These are inconclusive launch attempts, with zero test pass/fail counts.
- Subsequent SSD file opens, including test logs and a fresh output-directory probe, also stalled. A direct focused package run could not start while its output file creation was blocked. No stalled run is reported as passing.
- Whitespace and project generation checks passed. Full hosted PR validation is required before merge.

Build logs and attempted-run evidence are retained under `/Volumes/MacMiniSDD/HarcBuilds/library-selection-20261102`; a task checkpoint is at `/private/tmp/harc-library-selection-state.json`. Internal free space recovered above the 5 GiB floor before any cache relocation completed, so the original caches remained unchanged. No canonical audio, Library, keys or storage preferences were modified.

The published 0.14.20 artifact is unchanged. This fix requires a separately validated update before it reaches an installed app.
