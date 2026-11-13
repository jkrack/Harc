# Recording-time presentation and preview load

## Findings and scope

The inspected desktop build contains two avoidable-work paths during recording:

1. Raw level values and rolling histories publish on the broad application bridge,
   which the Library root observes. This can invalidate list filtering/grouping
   along with the small meters. SwiftUI may coalesce notifications; source
   inspection alone does not establish a frame-time or CPU cost.
2. Live preview waits five seconds after its last inference, then re-transcribes
   the growing uncommitted tail. Normal chunks are sixty seconds. The existing
   thirty-second preview setting was stored but unused; the old maximum was
   twice the chunk duration, mainly affecting backlogged processing.

The changes are isolated from the separate stop-feedback/origin-label candidate.
No claim is made that they resolve every source of recording sluggishness or the
long-finalization hang in issue #105.

## Changes

- Meter histories have a narrow observable state. The card, island, menu and
  sidebar waveform subscribe directly; Library-wide observers do not.
- Raw dB diagnostic snapshots no longer publish unused per-buffer notifications.
- Visual histories are appended and trimmed before one publication per window.
  Auto-stop still consumes every level sample and its safety decisions are unchanged.
- Speculative preview honors its configured complete-span budget. If the full
  uncommitted span is too long, defer before temporary-WAV copying or inference.
- Keep the previous provisional text until a durable chunk commits. Do not stitch
  an incomplete rolling tail into a misleading full transcript. Durable chunks,
  retries, capture and final transcription remain unchanged.

With the defaults, provisional updates can pause after thirty seconds until the
next sixty-second chunk commit, potentially longer when processing is backlogged.
This is an explicit compute-versus-live-preview-latency tradeoff, not audio loss.

## Validation

- Initial and final incremental focused package runs: 57 tests in 10 suites
  passed on each run, zero skips.
- 100 synthetic meter-update cycles produced zero broad bridge notifications while
  meter-only notifications remained observable. Semantic safety/stop changes still
  publish through the bridge.
- Coverage includes auto-stop behavior, history publication/deduplication, preview
  input durations, retained provisional text, budget deferral/resumption, and full
  final synthetic-audio coverage including retry behavior.
- Independent source review found no blocking issue.
- Isolated Debug Xcode app build passed, including both embedded helpers.
  The app was not launched or installed; this is compilation evidence, not
  end-to-end UI execution or release qualification.

## Limits

No installed-app update, real recording manipulation, content inspection, settings
change, publication, merge or release was performed. No end-to-end UI execution or
runtime frame-time/CPU improvement measurement is claimed. Focused tests do not
replace full CI or physical-device qualification.
