# PR 4 protobuf/signing wire validation

**Date:** 2026-08-02

**Status:** Software gates accepted; physical codec gate remains open

## Accepted software gates

| Gate | Result |
| --- | --- |
| Protocol schema guard | Passed: exactly 7 schemas, 6 services, 25 RPCs, and 28 closed enums; checksum inventory, generator configuration, and prohibited-concept scans passed |
| `HarcProtocolWire` and `HarcProtocol` SwiftPM builds | Passed with pinned generated sources and handwritten validation layer |
| Harc protocol test matrix | 76 tests / 14 suites passed |
| Full `swift test` | 1,064 Swift Testing cases / 176 suites ran with seven pre-existing load-sensitive timing issues while four Core ML encoder compilations each occupied about 45 seconds; all three affected suites immediately passed 18/18 tests in isolation |
| Xcode project generation | Passed |
| Unsigned resident Mac app build | Passed for macOS arm64, including embedded `harc-stt` and `harc-mcp` executables |
| `HarcProtocol` portability | Passed for generic iOS Simulator, arm64 and x86_64, with Xcode's explicit local package-plugin validation skip |
| Existing portable targets | `HarcClientStore` and `HarcMobileSpikes` each passed a generic iOS Simulator build |
| External construction boundary | External Swift code cannot construct package-minted trust evidence or a live current-grant binding, and cannot access the Host internal testing seam |
| SwiftPM resolution | Stable after `swift package resolve`; exact pins are gRPC Swift 2.4.2, gRPC Swift Protobuf 2.4.1, and Swift Protobuf 1.38.1 |
| Patch hygiene | Schema checksum verification and `git diff --check` passed |

The protocol matrix exercises all 25 generated RPC request/response and
streaming types, all nine signed-object registry rows, exact-byte golden
vectors, low-S signatures, protobuf compatibility, every domain conversion,
capability negotiation, independent pairing/session encodings, `HARCAB1`,
`HARCPB1`, portable trust history, and live command acceptance.

## Full-suite qualification

The repository-wide run is not represented as a clean 1,064/1,064 pass. Four
concurrent Core ML `Encoder.mlmodelc` compilations each took about 45 seconds and
starved short polling deadlines in these existing suites:

| Affected suites | Full-run issues | Immediate isolated result |
| --- | ---: | --- |
| `SummarizationQueue`, `SummarizationQueueStore`, and `LibraryMaintenanceStore` | 7 | 18/18 tests passed in 3 suites |

The isolated run used the exact just-built test binary. No protocol, identity,
transfer, host, client-store, or app build gate failed.

## Independent adversarial audit closure

The final PR 4 audit found and closed six concrete edges before commit:

- an unauthenticated portable-history payload could enter recursive nested
  parsing before the outer signature was verified;
- the authentication purpose was not retained, so historical processing
  evidence could be promoted into a live command value;
- live command acceptance reduced current authorization state to only a public
  grant UUID/epoch pair;
- exact-container count and aggregate-size limits could be enforced only after
  generated protobuf arrays or caller framing work had already allocated; and
- `SubmitOwnArtifact` and `GetAudio` had streaming shapes but no frozen
  contiguous framing, bounded-storage, resume, EOF, or exact-length/hash rules.
- the specialized verified host-transport decoder interpreted its independent
  binary payload before authenticating the outer signed frame.

The accepted implementation now:

- verifies an admitted signed frame before any registered payload decode;
- admits the exact expected nested grant/revocation tuple before typed decode,
  with explicit depth, device, per-device, and aggregate history ceilings;
- retains historical versus initial-command assurance on the authenticated
  result and requires the latter for a processing submission;
- package-mints live-grant snapshots from a complete active registry entry and
  rechecks protocol, library, authority, device key, status, grant ID/epoch,
  issue/expiry window, and operation-specific scope;
- precomputes container cardinality and total size with overflow-reporting
  arithmetic, wire-counts repeated header fields before generated parsing, and
  preflights bounded transcript, word, turn, range, and revision collections;
  and
- normatively freezes first-message ordering, contiguous indexes/offsets,
  bounded nonempty frames, resume behavior, half-close EOF, bounded staging,
  and exact declared length/hash validation in the two streaming schemas; and
- authenticates the transport-set frame before its independently encoded
  endpoint payload is interpreted.

Regression tests cover each failure mode, including an invalid outer signature
around a deeply nested payload, wrong nested signed-object type, excessive
history/container collections, historical-to-live promotion, cross-library,
cross-authority, wrong-device/key, revoked, expired, future-issued, stale-epoch,
and missing-scope grant snapshots.
The transport regression additionally signs a malformed payload, tampers the
outer signature, and requires signature rejection to win over payload parsing.

## Exact-wire and compatibility result

- All nine registered objects preserve the original header, payload, signature,
  complete frame, and derived object ID.
- Unknown additive protobuf fields survive only through untouched exact bytes.
  Unknown required features, critical fields, majors, and closed enum values
  fail closed.
- The reviewed golden corpus contains 33 logical vectors covering signed rows,
  bootstrap/pairing/session values, both exact containers, negotiated
  capabilities, static SHA-256, and additive-unknown compatibility.
- Generated Swift remains untracked build output. `Protos/` is the only schema
  source of truth.
- Network listeners, Bonjour, TLS issuance, gRPC adapters, canonical audio
  publication, and UI activation remain outside this slice.

## Codec gate still open

No physical iPhone was attached. CAF+ALAC and FLAC therefore still lack the
required three-hour, bit-exact, oldest/current-device qualification reports.
PR 4 intentionally carries negotiated codec/container identifiers without
selecting a release codec.

PR 5 may build the complete codec-neutral ingest, canonical publication,
receipt, recovery, and processing pipeline. Raw canonical PCM remains
fixture-only, and every production decoder/commit path must fail closed with a
typed unavailable result until one physical-device candidate satisfies the
specification's qualification gate.
