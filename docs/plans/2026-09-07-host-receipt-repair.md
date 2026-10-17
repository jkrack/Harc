# Host receipt replay recovery

Status: isolated diagnostic build 0.14.12 (67.1), source `8081328a6dc95b4be6ddc93629e7c06d3040bbb5`, installed on the Mac mini. Owner-authenticated repair and real Client qualification are pending. Not release-qualified.

## Observed problem

A real desktop Client authenticates successfully, then repeatedly receives an internal gRPC error when retrying an already-committed origin. On the resident Host, the canonical WAV still has the journaled PCM hash, inode, size, owner and private permissions. Its device number and ctime differ. The actual artifact validator rejects this identity and receipt replay consequently fails closed. Why the metadata changed is not established; a matching hash is not permission to overwrite the journal automatically.

This is separate from another upload hitting the installed Host's disk reserve. Capacity restoration must be verified through durable chunk acknowledgements, not a single free-space reading.

## Required behavior

- Preserve the exact receipt, canonical recording, origin, audio hash, Library and Host authority. Never ask the Client to forget pairing to repair a canonical artifact.
- Show an actionable Host artifact-repair concern rather than presenting it as a lost route or generic internal exception. Client masters remain protected until existing verified-receipt rules complete.
- Keep normal receipt replay fail-closed for identity mismatches. Expose an explicit local Host repair operation with an auditable before/after record and current-owner authorization; do not silently repair through an incoming Client request.
- Repair opens the existing canonical path through the trusted root without following symlinks, verifies private single-link ownership, exact WAV layout and full PCM hash against immutable publication evidence, and retains the descriptor. Recheck descriptor, pathname and root binding after validation and at the durable transition. A failed check leaves all old evidence unchanged.
- Coordinate repair with the resident writer lease and processing ownership. Atomically append an immutable repair authorization bound to the unchanged publication/receipt evidence. Keep the original publication identity immutable; validate the complete repair chain before using its effective identity. Define crash recovery before implementation. Do not use an external script to rewrite live HostDB fields behind the resident runtime.
- Separate transient descriptor identity from durable volume/file identity in future journals. Evaluate volume UUID plus file identity for persistence. Do not weaken in-process inode/ctime checks, and do not automatically migrate legacy rows by trusting the current path.
- Add BeginUpload diagnostic events to both foreground uploader paths and preserve safe RPC status/message in Settings. Capacity and artifact repair must remain distinct from trust failures.

## Validation required

1. Exact source tests for repair success with unchanged audio and deliberately changed metadata; unchanged receipt bytes and one canonical row after retry.
2. Reject wrong audio, wrong owner, unsafe permissions, hard links, leaf/ancestor replacement, replacement during hashing, changed immutable receipt/manifest evidence, wrong Host authority, and unauthorized repair.
3. Interrupt each repair durability boundary and reopen twice. Preserve old binding or recover the fully authorized new one; never leave a cleanup-authorizing partial repair.
4. Preserve existing missing/replaced WAV receipt-replay tests, including same-byte replacement. Ordinary replay never invokes repair implicitly.
5. Exercise actual pinned direct and encrypted relay Client delivery, lost receipt response, Host restart, processing and speaker reconciliation.
6. Qualify the personal MacBook Pro Client on the local network with both affected origins; no readiness claim based on package tests alone. Qualify the work Mac separately afterward.

The implementation must respect AGENTS.md's fail-closed canonical binding requirement. This plan does not authorize a production journal rewrite or claim a completed fix.


## Implemented scope

The local Host settings action checks committed recordings, requests macOS owner authentication for an eligible metadata mismatch, and accepts only unchanged inode, owner, permissions, link count, file length and fully verified signed receipt/audio content. It supports changed device-number/ctime metadata only. Missing audio and replacement inodes remain failures, including same-byte replacements. Schema v7 adds immutable repair provenance; it does not alter the original publication identity. Receipt replay consumes a validated chain of authorizations tied to the same exact receipt. No network RPC can authorize repair.

The isolated candidate passed an Xcode app build, 18 canonical-ingest/receipt-recovery tests, one direct pinned-TLS pairing lifecycle test, and the same lifecycle through the local encrypted-relay emulator, with no skips in these selected runs. Its source snapshot was clean and unchanged, and its Developer ID signature verified before installation. The previous app and both databases were backed up. Read-only comparison after upgrade confirmed both original publication identities and exact signed receipts were unchanged; the new repair table contained zero records. The upgraded resident Host listened on its existing ports. This is software and installation evidence, not real-client completion.

Remaining qualification includes real owner authentication (the Mac mini desktop was locked at the attempted UI step), personal MacBook Pro receipt persistence and queue clearing, playback/processing/speaker outcomes, and interruption exercises. An injected transaction failure test is not a physical power-loss test. Persistent volume identity remains future work; this repair does not claim to eliminate all reasons for metadata drift.
