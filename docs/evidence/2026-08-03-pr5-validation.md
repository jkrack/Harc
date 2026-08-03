# PR 5 canonical-ingest and durable-receipt validation

**Date:** 2026-08-03

**Status:** Software gates accepted; physical codec gate remains open

## Accepted software gates

| Gate | Result |
| --- | --- |
| `HarcHost` SwiftPM build | Passed with the canonical publisher, retained-root filesystem boundary, restart journal, receipt facade, and processing handoff |
| PR 5 focused matrix | 94 tests passed across writer leasing, WAV assembly, Host migrations, bounded staging, ingest recovery, receipt claims/codecs, transfer/outbox replay, local ingest, and canonical-library integration |
| Ingest crash stability rerun | 10 tests / 1 suite passed, including all 16 named publication failure points |
| External construction boundary | Passed; external modules cannot invoke raw Host-store receipt-return paths or mint package-owned trust evidence |
| Full `swift test` | 1,108 Swift Testing cases / 181 suites ran; every PR 5 test passed, while three pre-existing load-sensitive async maintenance assertions failed and their exact 12-test group immediately passed in isolation |
| Xcode project generation | Passed |
| Unsigned resident Mac app build | Passed for macOS arm64, including embedded `harc-stt` and `harc-mcp` executables |
| SwiftPM resolution | Dependency pins are unchanged; the manifest origin hash reflects the new declared `HarcHost`/test dependency on `HarcStore` |
| Patch hygiene | `git diff --check` passed |

The focused matrix was composed of:

| Suite | Tests |
| --- | ---: |
| Host writer lease and canonical commit | 9 |
| Canonical WAV assembly | 8 |
| HarcHost database migrations | 8 |
| Host upload state and bounded staging | 31 |
| Canonical ingest saga and receipt recovery | 10, including 16 parameterized kill-point cases |
| Recording receipt claims | 2 |
| Recording evidence codec | 5 |
| Upload attempt and outbox | 13 |
| Recording ingestor | 5 |
| Canonical library integration | 3 |
| **Total** | **94** |

## Full-suite qualification

The repository-wide run is not represented as a clean 1,108/1,108 pass. It
reported three load-sensitive issues while the real Core ML and daemon suites
were active:

| Affected suites | Full-run issues | Immediate isolated result |
| --- | ---: | --- |
| `SummarizationQueue` and `LibraryMaintenanceStore` | 3 | 12/12 tests passed in 2 suites |

The complete PR 5 ingest suite passed inside that same full run, including the
post-canonical-database-commit crash boundary that had exposed a real replay
precision bug during qualification. No Host, Store, Transfer, Protocol, receipt,
artifact-integrity, or app-build gate remained failing.

## Canonical publication and recovery result

The accepted implementation fixes the publication order around one canonical
artifact and one durable receipt:

1. the Host authorizes and snapshots the exact device, grant, generation,
   manifest, and origin identity before filesystem effects;
2. descriptor-bound staged files are prehashed, decoded through a bounded
   streaming interface, and posthashed without handing mutable paths to the
   decoder;
3. the canonical WAV is assembled in an exclusive same-directory temporary
   file, synchronized, atomically renamed, and followed by destination-directory
   synchronization;
4. the Host captures device, inode, owner, mode, link count, byte count, and
   change-time identity from the validated open descriptor and persists that
   identity with the published-audio checkpoint;
5. the canonical recording row and initial change-log entry commit under the
   process-lifetime Host writer lease;
6. Host publication linkage, exact manifest and receipt sidecars, and the exact
   signed receipt bytes become durable before the receipt can be returned; and
7. processing is handed off asynchronously with the canonical ID, retained-root
   WAV path, PCM hash/frame claims, and artifact identity. Processing failure
   cannot retract playable committed audio or its receipt.

Every receipt-bearing application facade reopens the WAV through the retained
canonical-root descriptor and revalidates the persisted identity and canonical
content before returning cleanup-authorizing evidence. Raw Store
`beginUpload`/reconciliation receipt paths are package-internal and are rejected
by the external compiler boundary fixture.

## Crash, replacement, and replay closure

The named crash matrix covers all 16 publication seams, including:

- temporary-file creation, assembly, and synchronization;
- rename and destination-directory synchronization;
- canonical Store commit and Host linkage;
- receipt creation, persistence, both sidecars, and directory synchronization;
- lost response after the receipted commit; and
- processing handoff before and after scheduler acceptance.

Recovery returns one byte-identical receipt, one canonical row, and one WAV.
An occupied destination is never overwritten. A moved canonical root, deleted
WAV, same-byte path replacement, hard link, symlink, ancestor replacement, or
same-inode mutation cannot produce a receipt or processing handoff.

Qualification also found that GRDB's millisecond datetime text round-trip may
represent the same instant a fraction of a microsecond away from the original
Foundation `Date`. The origin replay guard now compares exact Unix-millisecond
identities while keeping canonical IDs, hashes, frames, and paths byte-exact.
A deterministic regression at a known failing millisecond proves replay across
reopen succeeds and that a one-millisecond change still fails closed.

## Migration and writer authority

HostDB schema v3 persists all eight artifact-identity fields, encodes full-width
unsigned filesystem values without loss, enforces all-or-none presence and
immutability, and quarantines pre-v3 rows that had crossed publication without
historical identity evidence. It never reconstructs trusted identity from a
current pathname.

Only the live Host writer lease can enter the canonical remote-commit path in
`HarcStore`. Recovery must present the exact library, host-authority, and
host-state tuple, and the initial canonical commit/change evidence is exact-
idempotent across process reopen.

## Independent adversarial audit closure

The final audit found no remaining P0 or P1 issue in artifact identity, retained
root handling, journal recovery, receipt replay, or processing handoff. It
specifically verified that orphan Store rows cannot produce receipts or adopt a
replacement file, every receipt-return surface passes artifact revalidation,
and processing revalidates the exact artifact immediately before handoff.

## Codec gate still open

No physical iPhone qualification report exists yet for CAF+ALAC or FLAC. PR 5
therefore remains codec-neutral: raw PCM is accepted only by the explicit
fixture decoder, and the shipping decoder fails closed with a typed unavailable
error. No release codec is selected or implied by these software results.

PR 6 may now activate pairing, pinned TLS, discovery, gRPC/HTTPS adapters,
background capabilities, authenticated local MCP IPC, and resident Host
composition on top of this transport-neutral ingest facade. It must not weaken
the retained-root artifact checks, writer authority, exact receipt semantics, or
the open physical codec gate.
