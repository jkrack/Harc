# PR 6 Bootstrap Transport Validation — 2026-08-03

## Scope

This checkpoint activates the frozen-v1 public bootstrap, QR pairing, and
session-establishment path across the protocol-neutral Host core, generated
gRPC Swift 2 service/client adapters, per-stream pinned TLS binding, the resident gRPC
server lifecycle, and a real Network.framework TLS 1.3 loopback. It does not
yet activate authenticated recording transfer, the background HTTPS body
handler, Bonjour, or the app/CLI composition roots.

## Implemented boundaries

- `HarcHostInfoService` exposes only the canonical host identity tuple,
  capability offers, the exact current authority-signed transport set, and
  server time. Both public methods share one 60-request/source/minute limit and
  fail closed while serving-bootstrap or transport publication is incomplete.
- Generated HostInfo, Pairing, and Session service adapters validate protobuf
  before calling `HarcHost`, preserve exact signed-object and negotiated-payload
  bytes, bind pre-authentication source facts, and parse one canonical pairing
  bearer.
- `HarcBootstrapGRPCServiceFactoryV1` is the production composition root. It
  owns one host-scoped source-binding provider and one malformed-input cooldown
  gate for HostInfo, Pairing, Session, and the HTTP/2 source bridge. Concrete
  adapter construction and the raw runtime service-array seam are internal test
  seams. The current production call graph uses only the factory; this is a
  reviewed/tested invariant, not target-level Swift access control.
- The source bridge reads the accepted `NWConnection` endpoint, removes the
  ephemeral port, normalizes IPv4, IPv4-mapped IPv6, IPv6, and canonical Unix
  domain sources, and injects one authenticated 64-byte internal token before
  gRPC metadata parsing. Client copies and trailer copies are stripped;
  unknown, nonnumeric, missing, duplicate, and forged sources fail closed.
- The active gRPC transport configures a 1 MiB raw predecode ceiling. Adapter
  checks remain defense in depth, and the duplicate-singular-field regression
  proves enforcement cannot depend on protobuf reserialization.
- `HarcPinnedGRPCConnection` owns one pinned TLS 1.3/h2 transport, one stateless
  owner-local response-trust codec, and all seven HostInfo, Pairing, and Session
  RPC calls. Every physical connection records its accepted trust before TLS
  verification completes; each HTTP/2 stream injects a fresh HMAC-SHA256-sealed
  envelope from its exact parent connection. The generated adapter authenticates
  the envelope, reparses its exact leaf, re-verifies the authority-signed
  transport set, and reconstructs trust before returning the response. Peer
  copies and trailers are stripped; missing, malformed, duplicate, tampered, or
  wrong-owner envelopes fail closed. Abandoned or retried streams retain no
  mutable registry entry and cannot exhaust shared response-binding capacity.
- `HarcBootstrapClient` validates the TLS-authenticated host tuple and exact
  transport object, proves the QR-bound pairing transcript, verifies the
  returned host-signed grant, and opens a device-signed session. Cancellation
  checks prevent new or late follow-up RPCs, discard credentials returned after
  cancellation, and retain claimant material when approval polling is
  cancelled.
- Pairing state is generation-guarded across suspension points. Concurrent
  begin/poll operations and local abandon cannot overwrite or resurrect a stale
  claim. Session bootstrap enforces grant identifier/epoch continuity,
  protocol compatibility, one unchanged TLS SPKI, and nonzero token material.
- TLS certificate serial canonicalization retains a required leading positive
  sign octet. This closes the intermittent negative-DER-serial failure exposed
  by the real loopback. One process-wide recursive Security.framework
  transaction gate now also keeps key create/load/delete and certificate
  install/identity-resolution/removal atomic across parallel suites and runtime
  callers.
- Generation termination reports the exact generation only after teardown.
  The resident recovery scheduler applies backoff without overlapping
  generations, invalidates stale bindings, and can recover after unexpected
  gRPC exit.
- The active bootstrap edge disables gRPC message compression. Future recording
  transfer uses independently decodable application-level lossless chunks; the
  CAF+ALAC versus FLAC release choice remains pending its physical-device gate.

## Focused validation

| Command | Result |
| --- | --- |
| `swift test --filter 'GRPCResponseTrustBindingTests|TransportTrustAdapterTests|PinnedGRPCTLSFeasibilityTests|HarcBootstrapClientTests|PinnedGRPCLoopbackIntegrationTests'` | Passed 34/34 across 5 suites |
| Comprehensive bootstrap/transport filter covering 21 host, identity, server/client transport, lifecycle, trust, and real-loopback suites | Passed 132/132 concurrently across 21 suites |
| `swift test --filter SummarizationQueueTests` | Passed 6/6 after hardening the pre-existing scheduler-sensitive test harness |
| `swift test --filter 'LibraryMaintenanceStoreTests|SummarizationQueueStoreTests'` | Passed 12/12 after condition-first monotonic polling replaced wall-clock deadline false negatives |
| Combined contention regression filter covering queue, maintenance, post-stop, preview, status, keep-warm, and ordinary cancel harnesses | Passed 40/40 across 8 suites |
| `swift test` | Passed 1,296 Swift Testing tests across 212 suites plus 121 XCTest tests; 4 opt-in model/quality integration tests skipped; Swift Testing phase 75.876 s |
| `git diff --check` | Clean |

The focused client run contains 17 bootstrap-client tests, 7 adversarial
response-to-TLS binding tests, 6 trust-adapter tests, 3 pinned-channel API tests,
and 1 real pinned-TLS loopback. The expanded checkpoint totals 132 passing tests
across 21 suites under Swift 6 strict concurrency, including concurrent
Security.framework fixture activity.

The loopback uses a real TLS 1.3 Network.framework listener, a real
Security.framework P-256 identity and leaf certificate, the production pinned
client, the production runtime initializer and factory-to-runtime wiring, and
the production source bridge. It verifies the authority-pinned handshake, exact
certificate DER and SPKI, exact authority-signed transport-set bytes,
per-stream response-to-TLS binding, normalized source binding, HostInfo
projection, and clean client/server shutdown. The fixture deliberately uses a
test-bound SPKI, the unready-listener seam, and the factory's injected-service
initializer; it does not validate the resident lease-to-served-identity binding
or the concrete application-service factory initializer.

## Dependency and wire checks

- `HarcHost` has no `HarcProtocol`, generated wire, gRPC, NIO, Network, or
  socket-adapter dependency.
- `HarcHostTransport` directly depends on `HarcHost`, `HarcIdentity`, and
  `HarcProtocol`, plus the pinned gRPC/NIO transport runtimes. The source bridge
  has explicit `NIOHTTP2` and `NIOHPACK` dependencies.
- `HarcClientTransport` imports the supported `HarcProtocol` surface and does
  not directly import `HarcProtocolWire`. Its raw client stream trust bridge has
  explicit `NIOHTTP2` and `NIOHPACK` dependencies.
- Generated sources remain build-plugin output. The handwritten
  `HarcProtocol` module owns the single generated-wire re-export seam; no
  generated file was edited.
- Exact negotiated capability bytes and their SHA-256 are preserved through
  negotiation, session proof, and Host session persistence.

## Remaining PR 6 gates

- Extend the active pinned TLS loopback beyond HostInfo through QR pairing and
  session establishment.
- Add the physical overlapping A/B rotation test which holds a response on the
  old TLS connection while a replacement connection authenticates, then proves
  both responses retain their own SPKI. Current unit coverage independently
  proves the connection holder, stream-header injection, envelope authentication,
  and trust reconstruction components; the one-connection loopback proves their
  production wiring. It does not substitute for overlapping physical A/B timing.
- Add authenticated session metadata/interception and the RecordingTransfer,
  Library, and Processing generated service edges, including five-second
  revocation checks for active streams.
- Activate the narrow HTTP/1.1 background batch runtime and handler over the
  same ingest service, including no-redirect and exact-body idempotency tests.
- Add Bonjour publication/discovery, bounded route-change recovery, app/CLI
  composition, same-UID local MCP IPC, entitlements, and Mac host controls.
- Re-run the full Swift suite after the remaining edges, then finish XcodeGen
  generation and an unsigned Xcode build before the PR 6 handoff.
