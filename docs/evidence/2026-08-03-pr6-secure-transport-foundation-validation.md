# PR 6 secure transport foundation validation

**Date:** 2026-08-03

**Status:** Foundation accepted; live transport, discovery, IPC, CLI, and
physical-device gates remain open

## Accepted foundation gates

| Gate | Result |
| --- | --- |
| `HarcHost` SwiftPM build | Passed without a dependency on `HarcProtocol`, `HarcProtocolWire`, gRPC, NIO, Network.framework, or socket adapters |
| `HarcHostTransport` SwiftPM build | Passed with the v1 authentication and transport-set protocol adapters |
| Deferred resident startup | 8 tests passed across dual-journal preflight/reconciliation, stale plans, impossible protected-key role matrices, and canonical-tuple rejection |
| Pairing and sessions | 11 tests passed across one-time claims, golden SAS proof, local approval, re-adoption, capability negotiation, challenge consumption, expiry, and revocation |
| Transport-set lifecycle | 15 tests passed across exact recovery, protected high-water marks, rotation, one-shot role-bound listener leases, partial activation, and validity hard stop |
| Production protocol adapters | 4 tests passed across exact pairing proof/SAS, negotiated capabilities, session proof, authenticated transport-set issue/decode, tamper, wrong-authority, and canonical-order rejection |
| Protected identity and authority mutation | 26 tests passed across key creation/deletion journals, TLS identity, exact tuple binding, FIFO authority mutation, emergency repair, and deferred security reconciliation |
| Wire, file, TLS trust, and adapter boundaries | 32 tests passed across HARCAB1 bounded file parsing, exact signed ACKs, raw-DER leaf validation, pinned trust progression, and disjoint HTTP/2/HTTP/1.1 listener policy |
| Host migrations and security registry | 29 tests passed across schema v5, crash recovery, grant mutation, same-key re-adoption, protected rollback detection, and emergency trust repair |
| Patch hygiene | `git diff --check` passed |
| **Focused total** | **125 tests passed in 16 suites** |

## Dependency and trust boundary

`HarcHost` owns durable host state, authorization, lifecycle invariants, and
protocol-neutral proof inputs. It no longer imports or links the wire protocol
target. `HarcHostTransport` is the composition layer that admits exact v1 wire
objects and implements frozen transcript, capability, and transport-set
semantics.

The resident startup sequence is fail-closed:

1. inspect the protected cryptographic state without exposing private keys;
2. preflight the security and HostDB transport journals without mutation;
3. reconcile only the exact captured plans;
4. complete cryptographic bootstrap;
5. decode or issue the authenticated transport set through the injected v1
   boundary; and
6. bind each TLS server identity once to its exact listener role before the
   generation becomes active.

An invalid or stale plan cannot advance a protected high-water mark. A listener
identity cannot be copied out of the lifecycle, rebound, used for the wrong
role, or activated after its generation becomes stale.

## Batch evidence foundation

The HTTPS batch path now has two transport-independent primitives ready for its
live adapter:

- a bounded file-backed HARCAB1 scanner that validates immutable capability and
  chunk evidence without reading the complete request body into one `Data`;
- an exact signed batch acknowledgement whose immutable request binding and
  accepted-chunk set must validate before the client may persist cleanup
  authority.

These primitives do not claim that the live HTTP/1.1 endpoint or background
URLSession workflow exists yet.

## Open PR 6 gates

This checkpoint is not PR 6 completion. The following remain required:

- live gRPC HostInfo, Pairing, Session, RecordingTransfer, Library, and
  Processing service adapters and client connection state machine;
- active-stream revocation within five seconds;
- schema-backed background capabilities and the live no-redirect HTTPS PUT
  endpoint;
- Bonjour advertise/discover and persisted listener-port recovery;
- authenticated same-UID local IPC for `harc-mcp`, with no Host-mode direct
  database fallback;
- resident Mac app composition and lifecycle controls;
- the CLI discover/pair/reconnect/upload/read-status end-to-end path; and
- physical `HarcMobileSpikes` evidence for background TLS, delayed upload,
  restart/DHCP and route changes, authorized leaf cutover, and gRPC
  TransportServices feasibility.

The physical-device evidence remains an external qualification gate and will
not be inferred from simulator or loopback software tests.
