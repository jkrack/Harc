# Harc Remote Relay Specification

**Status:** Approved extension

**Date:** 2026-08-08

**Extends:** [Host/client/mobile implementation specification](2026-08-02-host-client-mobile-implementation-spec.md)

**Architecture:** [Harc Remote relay architecture](../architecture/harc-remote-relay.md)

**Delivery plan:** [Harc Remote relay buildout](../plans/2026-08-08-harc-remote-relay-buildout.md)

## 1. Purpose

Harc Remote lets an adopted iPhone or secondary Mac reach its one canonical
Host from a different physical network without opening an inbound port, running
a user-managed VPN, or sending recording content to a cloud processor.

The Host remains the only canonical library, identity authority, and automatic
inference destination. Cloudflare Workers and Durable Objects provide only a
blind, transient byte relay between outbound WebSocket connections.

This document changes the base specification only where it explicitly says so.
All capture durability, host receipts, signed provenance, authorization,
revision, recovery, and OKF rules in the base specification remain normative.

## 2. Product invariants

- One customer installation has exactly one active `HostAuthorityID` and one
  canonical `LibraryID`. Any number of explicitly adopted clients may connect.
- Harc Remote never makes the relay a host, library, processor, backup, or
  identity authority.
- Local recording never waits for the relay or Host. A client retains its
  durable master and retries through its existing outbox.
- Direct authenticated LAN transport remains preferred. Relay failure degrades
  only remote reachability.
- Audio, transcripts, summaries, speaker embeddings, OKF, grants, and Harc RPC
  plaintext are never intentionally exposed to or stored by Cloudflare.
- The existing pinned Harc TLS and signed application protocol run inside the
  relay tunnel. Cloudflare terminates only the outer WebSocket TLS connection.
- Every application byte MUST already be protected by the inner Harc TLS
  session before it is handed to the outer WebSocket. Decryption keys exist
  only in the paired Harc client and Host processes; the Worker, Durable
  Objects, Cloudflare logs, and Cloudflare operators never receive them.
- Pairing still requires possession of a short-lived invitation, proof of the
  device key, four-word SAS comparison, and approval on the Host.
- The production Worker disables persistent Workers Logs and Traces and exports
  no request telemetry. Cloudflare still processes minimum connection metadata
  in real time to service a request, but Harc does not retain it. Time-bounded
  staging observability contains no invitation, capability, device key,
  certificate, recording name, transcript, audio, or inner application frame.

## 3. Trust boundaries

The relay is an untrusted transport for content confidentiality and application
authorization. It may observe connection time, approximate byte counts, edge
location, IP addresses, opaque route identifiers, and failure status. It can
drop, delay, duplicate, reorder, or terminate outer frames. Existing Harc TLS,
signatures, sequence validation, idempotency, and durable upload reconciliation
MUST make those actions safe and visible.

The relay is trusted only to enforce best-effort resource admission and route
two sockets. A relay compromise MUST NOT reveal Harc content or create a valid
device grant. Denial of service remains possible and is handled as Host offline.

No Cloudflare product with payload inspection, persistence, analytics sampling,
AI inference, object storage, queue storage, or database storage may be inserted
into the content path without a new approved privacy specification.

“Blind relay” therefore means zero application-content visibility, not the
physically impossible claim that an Internet router sees no traffic metadata.
Cloudflare receives encrypted inner-TLS records and the minimum opaque routing
data needed to join two sockets; it never receives Harc content plaintext.

## 4. Topology and ownership

The public Worker performs bounded request validation and maps an opaque route
identifier to a `HostRendezvous` Durable Object. One rendezvous object represents
one Host authority without using the authority key or `HostAuthorityID` as its
name.

The Host maintains one outbound hibernatable WebSocket to its rendezvous object.
An adopted client uses a separate opaque device route and relay capability. On
successful admission, the rendezvous object creates an unpredictable session
identifier and one-time session capabilities. The Host and client then connect
to a `RelaySession` Durable Object that accepts exactly one socket of each role.

The session object forwards binary outer frames byte-for-byte. It does not
decode the inner TLS stream. It stores no content and becomes unusable after its
absolute deadline. A separate session object per active connection prevents one
busy client from sharing ordering or backpressure state with another client.

## 5. Relay identifiers and capabilities

Relay identifiers are independent of Harc domain identifiers:

| Value | Form | Rule |
| --- | --- | --- |
| `RelayRouteID` | 256 random bits, base64url | Opaque rendezvous object name; never derived from a public key |
| `RelayDeviceRouteID` | 256 random bits, base64url | Opaque per-grant lookup; revocable without changing device identity |
| `RelayCapability` | 256 random bits, base64url | Bearer admission secret; stored by the relay only as SHA-256 |
| `RelaySessionID` | 256 random bits, base64url | One active tunnel object; never reused |
| `RelaySessionCapability` | 256 random bits, base64url | One role and one session; consumed once |

Random values MUST use a cryptographically secure generator. Capability
comparison MUST be constant-time. Secrets MUST be passed in a dedicated header
or the first bounded control frame, never a URL, query string, log, diagnostic,
analytics event, or crash message.

The Host registers a hash of its rendezvous capability on first setup. A paired
device capability is installed only by the connected Host after the local Host
has approved the Harc grant. Revocation removes both the Harc grant and relay
capability. Key loss, Host-authority loss, or capability loss requires pairing
again.

## 6. Pairing invitations

The canonical `.harcpair` document remains a user-exported, short-lived bearer
invitation. When Harc Remote is enabled it gains an optional, versioned relay
route containing only:

- relay service origin;
- `RelayRouteID`;
- one-time pairing route and capability;
- the original ticket expiry; and
- an integrity binding authenticated by the Host-approved pairing proof.

The ticket envelope is not itself signed. Instead, a Remote ticket derives its
24-byte pairing admission bearer from a domain-separated hash of the complete
canonical ticket bytes. The Host stores only the binding of that derived bearer,
and the same binding is included in the device-signed pairing transcript and
SAS. Adding, removing, or modifying any relay endpoint therefore changes the
presented bearer and fails against the issuing Host's original reservation
before a claim can be approved. Direct-only tickets retain the frozen V1 raw-
secret behavior.

The invitation still expires after two minutes and is consumed at most once.
Email, Messages, AirDrop, a USB drive, or another user-selected share target may
carry the file; no Harc account or cloud mailbox is involved. Sending the file
through a third party exposes the temporary bearer invitation to that party, so
the UI MUST disclose that risk. Possession alone never bypasses device-key proof,
SAS comparison, or Host approval.

## 7. Tunnel behavior

- Both peers initiate outbound `wss://` connections on TCP 443.
- The client first attempts the direct LAN route for a short bounded interval,
  then races or falls back to its relay route according to network policy.
- The tunnel carries the byte stream produced by the existing pinned Harc TLS
  connection. Inner TLS certificate and authority verification are unchanged.
- Outer WebSocket messages are binary and no larger than 1 MiB. Text content
  frames are rejected after session setup.
- A session accepts exactly two roles, `host` and `client`; duplicate or third
  peers are rejected.
- Each forwarded message preserves message boundaries, and the Swift bridge
  treats their concatenated payloads as one ordered byte stream.
- If the receiver cannot accept data within its bounded queue, the relay closes
  both peers with an explicit overload code. It never buffers unbounded content.
- Idle sessions expire after 120 seconds without payload. Absolute session life
  is 24 hours; a continuing upload opens a replacement tunnel and resumes using
  existing Harc chunk reconciliation.
- Disconnect, expiry, relay restart, duplicate, or uncertain delivery is
  represented to Harc as a normal transport interruption. Application-layer
  idempotency decides what remains to upload.

## 8. Durable Object rules

`HostRendezvous` and `RelaySession` use the WebSocket Hibernation API:
`acceptWebSocket`, serialized attachments, and `webSocketMessage`,
`webSocketClose`, and `webSocketError` handlers. They MUST NOT use legacy
non-hibernatable acceptance.

Each class is introduced with a SQLite Durable Object migration. Durable storage
is limited to hashes and small control metadata required for admission,
revocation, expiry, and recovery across eviction. No relayed binary payload is
written to storage. Session state is fail-closed if attachments or required
metadata are missing after eviction.

## 9. Abuse, privacy, and cost controls

Initial service limits are deliberately conservative and configurable:

- 32 paired relay routes per Host;
- 8 concurrent remote sessions per Host;
- 1 connection attempt per device route per second with bounded burst;
- 1 MiB maximum outer frame;
- one 1 MiB frame credit per direction in the Swift bridge; the sender waits
  for an end-to-end receiver acknowledgement before reading the next frame;
- one matching outstanding-frame credit per direction in the Worker; a second
  binary frame before acknowledgement closes both peers with code `4429` and
  reason `receiver_overloaded`;
- 120-second idle timeout and 24-hour absolute timeout; and
- hard monthly alert thresholds before any automatic service expansion.

Persistent Workers Logs and Traces are disabled in production. Cloudflare's
aggregate service metrics may be used for availability and capacity without
exporting per-request records. A distinct, time-bounded staging deployment may
sample coarse status, latency, close category, and rounded byte counts for a
named release exercise. Payload logging and request-header logging are forbidden
in every environment, and staging observations are deleted under the recorded
retention schedule before production enablement.

Hibernation is mandatory because an idle Host rendezvous may remain connected
for long periods. Harc Remote pricing and quotas are based on measured relay
bytes and session activity, not transcript or inference usage. The product is
priced per Host; paired clients do not create separate canonical subscriptions.

## 10. Host requirements

Harc MUST validate and explain Host readiness before enabling remote service.
The initial supported minimum is:

- Apple Silicon Mac;
- 16 GB unified memory;
- macOS 26 or later;
- 50 GB free local storage after model installation; and
- launch at login enabled for an appliance-like Host.

Recommended is 24 GB memory, 512 GB or larger storage, wired Ethernet, and a
Mac that remains powered and awake. A 32 GB tier is recommended for concurrent
clients, larger local models, or aggressive reprocessing. These are product
support gates, not protocol requirements, and MUST be revisited with measured
ingest/inference concurrency.

## 11. Availability and user experience

Harc reports direct, remote, queued, Host asleep, Host offline, capability
revoked, and service unavailable as distinct states. “Saved locally” remains
the primary outcome whenever capture succeeded. Relay availability never
changes that message into failure.

The Host UI lists every paired device by its Harc device identity and display
name, last direct/relay connection, last successful transfer, and revocation
state. Opaque relay identifiers are available only in diagnostics.

## 12. Release acceptance and ongoing evidence

On 2026-08-09 the product owner accepted Harc Remote for general release as an
opt-in feature. The following matrix remains the required regression and
operational evidence checklist:

- Worker routing and input-bound tests;
- capability, replay, expiry, role, third-peer, and constant-time validation
  tests;
- binary byte-for-byte relay tests across Durable Object eviction;
- oversized frame, receiver loss, idle timeout, and reconnect tests;
- an inner pinned-TLS gRPC request through the local relay emulator;
- a negative wire-inspection test proving relay-visible frames do not contain
  known audio, transcript, gRPC, device-name, or speaker-identity plaintext;
- interrupted lossless upload resume without duplicate canonical recordings;
- iPhone and secondary-Mac tests across two unrelated networks;
- direct-LAN preference and relay fallback tests;
- confirmation that Cloudflare logs contain no content or secret headers;
- a load/cost run covering at least 1,000 idle Hosts and representative active
  audio transfer without unbounded memory or duration; and
- standalone, Host, Client, and iOS bounded regressions.

The production Worker is deployed at `https://relay.adaptcontext.com`. Released
clients keep Harc Remote off until the Host owner enables it; direct LAN remains
preferred whenever available.
