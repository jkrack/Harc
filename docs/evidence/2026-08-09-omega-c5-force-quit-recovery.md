# Omega C5 physical force-quit recovery evidence

**Date:** 2026-08-09
**Scope:** additional available-device diagnostic C5 pass
**Device:** Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6 (23G71), arm64

## Result

A focused physical UI test started real microphone capture in an isolated
application-support root, waited seven seconds so a durable checkpoint existed,
terminated the Harc process without asking capture to stop, and relaunched the
same root. The test passed with one test executed, no skips, and zero failures.
The relaunched UI showed **Recovered 1 durable recording** and returned to
**Ready to record locally**.

A read-only copy of the isolated root after relaunch contained exactly one
finalized WAV and metadata document.

## Artifact verification

| Check | Result |
| --- | --- |
| Finalization reason | `recoveredDurablePrefix` |
| Canonical frames / PCM bytes | 81,568 / 163,136 |
| Playable WAV | 16 kHz, mono, signed Int16, 5.098 seconds |
| WAV file bytes | 163,180, including the 44-byte WAV header |
| Full WAV SHA-256 | `4a480656e8eb5dee6fb6b729f0bf5503684931ff154bdbac4112625de497885a` |
| PCM SHA-256 | `FD2WvpYjlTp9GLEb+PLK2RKEPE1XoZ6K8+pkPWgtXog=`; independently recomputed from WAV audio bytes and equal to both metadata records |
| Discontinuities | one explicit `recovery` boundary at frame 81,568 |
| Finalized-capture row | one, `master_file_state = present` |
| Outbox | one, `localOnly` |
| Verified receipts / cleanup intents | zero / zero |

The process never claimed automatic capture continuation. Relaunch repaired the
playable prefix through the last durable frame, persisted it exactly once, and
did not claim upload or deletion. This satisfies the core C5 behavior on the
available Omega hardware.

The subsequently completed combined physical regression reran C5 successfully
as part of 30/30 Omega app/UI tests (24 hosted and six UI). Before the
first launch, a Debug-only argument removed only the exact UUID-scoped C5 test
root; the force-quit relaunch omitted that argument and preserved the interrupted
state. A new read-only copy therefore proved the rerun was uncontaminated: one
finalized WAV/metadata pair, one finalized-capture row, one local-only outbox
row, and zero upload attempts, receipts, or cleanup intents. The new 5.098-second
WAV contained 81,568 frames; its independently recomputed PCM SHA-256
`lot4FhnZcChhI79jaJwC9K2D+6zYTugpE35ce21zFCw=` matched its metadata.

The regenerated current candidate, HarcMobile 0.14.1 (56), then passed the
complete signed physical run on Omega: 30/30 tests (24 hosted app and six UI),
with no failures or skips. CoreDevice confirmed that exact version and build
installed on the identified `iPhone16,2`, iOS 26.6 (23G71). A fresh read-only
copy of C5 root `C5000000-0000-4000-8000-202608090001` again contained exactly
one finalized WAV/metadata pair, one finalized database row with the master
present, one `localOnly` outbox row, and zero upload attempts, receipts, or
cleanup intents. The 5.098-second WAV contained 81,568 frames; its full-file
SHA-256 was `eed786a859fb539d8d571d5d75d5e93aea7ff3d8284edc87c2decd4deedeafe8`,
and the independently recomputed PCM SHA-256
`x33078CJl+zyQxS/F5NKmjGp0dtbQ+eY1KzUHe2YR2I=` matched the JSON and database
metadata.

## Qualification boundary

This is one deterministic additional-device diagnostic from a dirty source
tree; the specification calls for randomized force-quit timing across the two
named launch roles. Repeat with varied termination points on the oldest launch
iPhone and the current non-Pro iPhone, from the exact sealed release source,
before promoting C5 or the overall physical matrix to pass.
