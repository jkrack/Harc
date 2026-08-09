# Omega C7 physical storage-exhaustion evidence

**Date:** 2026-08-09
**Scope:** additional available-device diagnostic C7 pass
**Device:** Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6 (23G71), arm64

## Result

The deterministic Debug-only C7 quota ran through the real microphone capture
path on Omega. The focused UI test passed with one test executed, no skips, and
zero failures. Harc remained in the foreground and visibly reported:

- **iPhone storage is full**;
- **Recording stopped. Harc saved the durable portion locally.**; and
- **Record Again**.

The test used an isolated application-support root and the documented
`160000`-canonical-byte quota. A read-only copy of that root after the test
contained exactly one finalized WAV and metadata document.

## Artifact verification

| Check | Result |
| --- | --- |
| Finalization reason | `storageExhausted` |
| Canonical frames / PCM bytes | 81,568 / 163,136 |
| Playable WAV | 16 kHz, mono, signed Int16, 5.098 seconds |
| WAV file bytes | 163,180, including the 44-byte WAV header |
| Full WAV SHA-256 | `c52fd16f1ee0124131fc38d9de3fd4cd889d08144f5b126eef40d39ba0955a8a` |
| PCM SHA-256 | `GnTcmi1v3KgDY2lK0l//KfdLD2NzDrmNRF156OumtlY=`; independently recomputed from WAV audio bytes and equal to both metadata records |
| Discontinuities | `writerFailure` and `recovery`, both explicitly anchored at frame 81,568 |
| Finalized-capture row | one, `master_file_state = present` |
| Outbox | one, `localOnly` |
| Verified receipts / cleanup intents | zero / zero |

The final master is nonempty and playable, the last durable frame is accounted
for, and the client does not claim upload or deletion. This satisfies the C7
required behavior on the available Omega hardware.

The subsequently completed combined physical regression reran C7 successfully
as part of 30/30 Omega app/UI tests (24 hosted and six UI). A
Debug-only argument first removed only the exact UUID-scoped C7 test root. A
new read-only copy therefore proved the rerun was uncontaminated: one finalized
WAV/metadata pair, one finalized-capture row, one local-only outbox row, and zero
upload attempts, receipts, or cleanup intents. The new 5.098-second WAV
contained 81,568 frames; its independently recomputed PCM SHA-256
`nnQW9LOCJlYdJnLHwkEq2w1CvX8BpgGn+l/40SpMucs=` matched its metadata.

The regenerated current candidate, HarcMobile 0.14.1 (56), then passed the
complete signed physical run on Omega: 30/30 tests (24 hosted app and six UI),
with no failures or skips. CoreDevice confirmed that exact version and build
installed on the identified `iPhone16,2`, iOS 26.6 (23G71). A fresh read-only
copy of C7 root `C7000000-0000-4000-8000-202608090001` again contained exactly
one finalized WAV/metadata pair, one finalized database row with the master
present, one `localOnly` outbox row, and zero upload attempts, receipts, or
cleanup intents. The 5.098-second WAV contained 81,568 frames and both
`writerFailure` and `recovery` markers at frame 81,568; its full-file SHA-256
was `308d654417e7cebdcba3c3258cbdb2fd6782871acc002708bd4931b542526875`, and
the independently recomputed PCM SHA-256
`Sj6rb8D6gHePyC21875ezeeyOeB4ryXGAOEgJ7trQaM=` matched the JSON and database
metadata.

## Qualification boundary

This is diagnostic evidence from the current dirty source tree, not a clean
sealed release build. It satisfies neither the unavailable oldest-device cell
nor the current non-Pro cell, and it does not cover the rest of C1-C6/T/P/H.
Repeat C7 on both named launch phones and on the exact release build before
promoting the overall physical matrix to pass.
