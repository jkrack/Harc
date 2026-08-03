# PR 3 — Identity, transfer, client store, and host core

**Status:** Software foundation validated; physical codec qualification pending

**Date:** 2026-08-02

**Normative source:**
[Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Applicable contract

This slice implements the PR 3-applicable foundations from Sections 6, 8–10,
12, 15–16, 23, 25, 26, and 29 of the normative specification. Its boundary is
the PR 3 requirement to:

> Activate `HarcIdentity`, `HarcTransfer`, `HarcClientStore`, and transport-free
> `HarcHost`; add `HarcHost.db`, migrations, key abstractions, state machines,
> authorization, staging, idempotency, and loopback application-service tests.

PR 3 does not add protobuf, gRPC, HTTPS, Bonjour, an enabled Host role, canonical
remote publication, or a production iOS application. Exact signed protobuf
objects land in PR 4; canonical WAV commit and durable receipts land in PR 5.

## Standalone behavior held unchanged

- The resident Mac application remains in Standalone mode.
- `AppDelegate`, `RecordingSession`, `StandaloneRecordingCommitter`, the current
  `harc-stt` lifecycle, and direct Standalone `harc-mcp` behavior remain unchanged.
- No new listener starts, no Bonjour service advertises, and no existing library
  is moved, uploaded, or reclassified.
- Existing capture still publishes through the tested PR 2 seam into the same
  destination, store, JSON/Markdown projections, tray, paste, and summary flow.

## Implementation order

1. Activate `HarcIdentity` and its tests. Add P-256 digest-signing primitives,
   exact key-derived IDs, key-store abstractions, installation-key loss policy,
   scopes, grant epochs, and revocation state. Keep PR 4 wire bytes opaque.
2. Activate `HarcTransfer` and its tests. Add host-neutral finalized captures,
   immutable typed chunk descriptors, frozen upload profiles, declarations,
   upload-attempt and outbox state machines, reconciliation, and receipt-domain
   placeholders without transport imports.
3. Activate `HarcClientStore` with two separate GRDB databases and tests. The
   transfer database owns trust and durable outbox state; the complete-protection
   library-cache database owns only path-free cache/cursor/conflict state.
4. Activate `HarcHost` with `HarcHost.db`, authoritative grant checks, operation
   replay, bounded staging, quotas, upload reconciliation/abandonment, and a
   distinct incomplete-upload recovery source. It must not issue a fake receipt.
5. Add the non-shipping iOS 18 `HarcMobileSpikes` harness. Compare CAF+ALAC and
   FLAC with bit-exact decoded PCM, latency, queue, memory, size, and thermal
   measurements. Freeze the release codec only after the physical-device gate.

The first four steps and the software portion of step 5 are complete. The
physical-device matrix remains intentionally open because no iPhone was attached
to the build host on 2026-08-02. Both lossless candidates remain representable;
neither is frozen as the production profile. PR 4 may proceed against the
codec-neutral contract, but production codec selection and PR 5 production
decode/commit remain blocked on the physical-device gate.

## Migration plan

### `HarcHost.db`

- V1 creates host metadata, device/grant/revocation state, pending security
  mutations, pairing placeholders, operation replay, uploads/generations,
  typed chunk declarations, staged-chunk journal, batch/capability placeholders,
  manifest/receipt byte slots, publication linkage, and bounded audit events.
- Private keys and raw pairing secrets never enter the database.
- Tests cover fresh creation, a seeded pre-v1 upgrade fixture, reopen, and
  idempotent migrator application.

### `HarcTransferStore.sqlite`

- V1 creates active/historical trust tuples, opaque exact grant/transport slots,
  finalized captures, recording and chunk outboxes, upload attempts, batches,
  task mappings, conflicts, exact manifest/ACK/receipt slots, and cleanup intent.
- V2 adds the permanent upload-attempt supersession edge that prevents an older
  upload ID from becoming eligible again after its replacement later expires or
  is abandoned.
- It contains no transcript, summary, speaker text, or general library cache.
- Tests cover fresh creation, seeded upgrade, preservation, and idempotent reopen.

### `HarcLibraryCache.sqlite`

- V1 creates only path-free cached recording metadata, cursor/tombstone state,
  offline metadata mutation placeholders, and visible conflicts.
- It does not mirror `HarcStore` and never becomes a canonical writer.
- Tests cover fresh creation, seeded upgrade, preservation, and idempotent reopen.

## Failure-injection and security tests

- Generated signatures verify over one precomputed digest; independent vectors
  catch accidental double hashing, high-S acceptance, wrong keys, and tampering.
- Missing known installation keys enter explicit key loss instead of silently
  changing `DeviceID` or re-attributing existing origins.
- Security-registry tests interrupt before the pending row, after the pending
  row, after the Keychain high-water mark, and before/after final DB apply.
  Only the exact one-revision pending lag may recover; rollback fails closed.
  Authority replacement and scope replacement require the correct local OS
  authorization, preserve registry monotonicity, and invalidate prior
  background capabilities atomically.
- Transfer tests reject gaps, overlaps, reorder, duplicate IDs, arithmetic
  overflow, size violations, profile mutation, conflicting replays, invalid
  transitions, stale generations, permanent-attempt supersession violations,
  and automatic retry from `securityBlocked`.
- Client-store tests inject trust-replacement rollback, lower/equivocating
  epochs, tuple-swapped validator evidence, revoked same-key re-adoption,
  missing files, protected-data unavailability, `synchronous=FULL` reopen, and
  restart reconciliation without making cleanup eligible before a verified
  receipt. A separate external compiler fixture proves callers cannot mint the
  package-only trust evidence or reach the Host package's internal testing seam.
- Host tests inject owner/scope/epoch mismatch, replay conflicts, declaration
  conflicts, corrupt/truncated/oversized bodies, quota exhaustion, symlinks,
  path traversal, per-device stream exhaustion, trusted-clock enforcement,
  mid-stream and post-fsync expiry, idle revoke/abandon/scope termination,
  staging write/sync/DB-ack boundaries, re-adoption ticket/auth failures, every
  security-journal crash point, and process reopen. Reaper tests cover the
  two-phase candidate/current-row check, compare-delete, reopen retention, and
  active-writer races.
- Schema-4 qualification tests require the complete 180-chunk, three-hour
  physical evidence envelope and reject synthetic-short, incomplete,
  reordered, aggregate-inconsistent, or nonphysical reports.
- Incomplete remote uploads remain a separate recovery listing and never enter
  the Standalone cache-recovery queue.

The final reaper audit found no P0 or P1 issue. Its one P2 immediate
post-reopen retry edge is closed: an intact durable pre-unlink claim from an
older generation is validated, restored, and exact-replayed instead of being
replaced. The deterministic staging regression suite passes 28/28.

## Exit gates

- Focused `HarcIdentityTests`, `HarcTransferTests`, `HarcClientStoreTests`, and
  `HarcHostTests` pass.
- Fresh/upgrade/idempotent migrations and reopen recovery pass.
- `xcodegen generate`, full `swift test`, and the unsigned Mac Xcode build pass,
  with only documented timing flakes accepted after an isolated green rerun.
- The signed physical codec harness records bit-exact and performance evidence
  on the named oldest-supported and current iPhones before the codec/container
  identifier is frozen. Simulator evidence is explicitly insufficient.
- PR 4 may proceed while that physical gate is open. PR 3 cannot exit, and PR 5
  cannot freeze or depend on a production codec/container, until it closes.

Detailed software-gate evidence is recorded in
[PR 3 validation](../evidence/2026-08-02-pr3-validation.md).
