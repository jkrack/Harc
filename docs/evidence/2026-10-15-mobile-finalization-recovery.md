# Mobile finalization recovery

The filesystem-to-outbox handoff can lose a recording from the local Library
without losing its WAV. The writer publishes the finalized WAV and metadata,
then removes its Active checkpoint before the app callback registers the outbox.
A process exit or failed callback in that interval leaves no checkpoint for the
old bootstrap scanner. Audio-session deactivation previously ran before the
callback and could cause the same result if it threw.

The fix registers the outbox before deactivation. Launch recovery also scans
unregistered finalized metadata, revalidates the producing identity and domain
invariants, and checks the canonical WAV header, exact length, and PCM SHA-256.
It uses the current container path and rejects symbolic links. Known outbox
origins are skipped, including origins whose masters were legitimately cleaned
up. Recovery grants no Host receipt or cleanup permission.

Validation used base `0ef6054cfcc099eda1e70c053eee687f71456ff5` and synthetic
bytes in isolated temporary directories. No phone recordings were inspected.

- The baseline reproduction finalized a synthetic master, omitted the app
  callback, and asked the old checkpoint scanner to recover it. Its single
  assertion failed because recovery returned an empty array.
- The review regression reproduced a second failure: one malformed orphan
  threw through the scanner and aborted recovery of a healthy finalized master.
  The corrected scanner reports each rejected artifact and preserves its bytes
  while admitting only independently validated masters. Directory setup and
  store errors still surface. The app shows a recovery warning and prepares
  capture independently of these orphan failures.
- All 12 durable-master tests passed with the corrected fix, including tests for
  mixed valid/invalid orphans, fatal setup failures, the handoff window,
  corruption, unsafe metadata, relocation, and cleanup.
  This focused macOS harness copied the exact `HarcDomain`, `HarcAudioMobile`,
  and writer-test sources into a minimal temporary package; it did not run the
  repository's complete package suite.
- Generic iOS `HarcMobile` build-for-testing passed with signing disabled and
  two workers. It compiled four new app tests for missing callback recovery,
  a throwing store callback, throwing audio-session deactivation, and mixed
  orphan recovery with an existing healthy Library and idle capture coordinator. Local
  execution remains pending because this Mac has no available simulator runtime.
  The mobile configuration CI script now selects these tests.
- Swift parsing, shell syntax, and `git diff --check` passed. The disk watchdog
  observed at least 12.60 GiB free during the app build.

Local diagnostic evidence is under `/tmp/harc-sync-evidence`: the baseline and
focused test logs, copied-source SHA-256 manifest, and generic iOS build log and
watchdog receipt. These temporary files are supporting diagnostics, not release
qualification artifacts.

This change does not qualify the codec or physical capture/transfer matrix.
Fresh exact-source direct-TLS and local-relay lifecycle runs remain open; earlier
historical evidence does not qualify this source. No pairing transport changed
in this slice. Follow-up investigations remain open for retry profile drift,
stale background completions after credential refresh, and forgotten-Host task
isolation.
