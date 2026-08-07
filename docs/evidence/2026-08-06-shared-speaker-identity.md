# Shared Speaker Identity and Host Authority

**Date:** 2026-08-06

**Status:** Source-complete and locally validated; not yet versioned or released

**Specification context:** [Host/client/mobile implementation specification](../specs/2026-08-02-host-client-mobile-implementation-spec.md)

## Outcome

Harc now treats the Host as the authoritative brain for speaker identity across
the standalone Host library, secondary-Mac Clients, and HarcMobile. Clients may
compute and cache provisional recognition results for low-latency local use, but
only the Host assigns stable Person identities and publishes canonical speaker
labels.

The implementation adds:

- stable public Person and speaker-prototype UUIDs with monotonic profile and
  recognition-pack revisions;
- a v18 canonical-store migration that preserves existing People and speaker
  embeddings while backfilling their stable identities;
- a compact, quantized recognition pack containing at most three representative
  prototypes per Person, delivered asynchronously over the authenticated pinned
  Host session and cached monotonically by each client;
- local desktop embedding and provisional cosine matching, followed by durable,
  idempotent observation submission to the Host;
- Host-side embedding generation for iPhone uploads, so mobile recordings join
  the same authority model without requiring a shipping iOS inference model;
- an observation journal and Host-side threshold decision that may accept,
  reject, or leave a client proposal pending review;
- exact-signed manual speaker assignment mutations using stable Host Person IDs;
- canonical transcript projection that regenerates speaker names from Host
  Person links; and
- transcript UI projection on macOS and iOS, including removal of the stray
  one-pixel vertical and horizontal divider artifacts.

## Trust and durability properties

- Three explicit grant scopes separate recognition-pack reads, observation
  writes, and authoritative assignment writes.
- Existing pairings do not silently gain the new privileges. They must be
  re-paired, and the desktop Client reports that requirement explicitly.
- Recognition packs are accepted only from the already authenticated and pinned
  Host session. Rollback and same-revision equivocation are rejected by the
  client cache.
- Observation operation IDs are deterministic and replay-safe. Audio upload is
  not repeated when the post-receipt speaker handoff is retried.
- The Host completes speaker observation and canonical projection work before a
  newly processed recording is published as ready, keeping partial work
  recoverable.
- No cloud transcription, voice processing, telemetry, or third-party speaker
  service was introduced.

## Validation

- The focused speaker, protocol, store, cache, STT, migration, and transcript UI
  suites passed 64 tests with no failures.
- The complete bounded SwiftPM regression initially exposed one stale v9
  migration fixture that inserted a post-v18 speaker embedding without its
  required prototype UUID. The fixture was corrected and the 26-test migration
  suite passed.
- The complete already-built rerun passed 1,520 Swift Testing cases in 257
  suites. The XCTest surface passed 123 cases with four integration tests skipped
  by their existing opt-in contract.
- The unsigned macOS `Harc` application build completed with
  `** BUILD SUCCEEDED **`, including `harc-stt` and `harc-mcp`.
- The unsigned generic iOS `HarcMobile` application build completed with
  `** BUILD SUCCEEDED **`.
- The focused macOS `HarcAppTests` target passed 10/10 tests, covering the
  application composition that owns desktop pairing, durable Client capture
  files, processing framing, and Host-audio cache policy.
- Validation was bounded to two workers on the 16 GB development Mac.
- `Package.resolved` is unchanged and `git diff --check` is clean.

## Remaining physical evidence

The source slice still needs a signed multi-device acceptance run after it is
versioned and installed: re-pair an iPhone and a secondary Mac, verify that both
receive the same recognition-pack revision, submit recordings from both, and
confirm that one Host Person assignment converges to the same canonical label on
all three devices. This is additive to the physical iPhone and secondary-Mac
gates already tracked in the main implementation status.
