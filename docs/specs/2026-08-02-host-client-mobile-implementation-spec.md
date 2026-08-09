# Harc Host, Client, and Mobile Implementation Specification

**Status:** Approved for implementation

**Date:** 2026-08-02

**Security clarification:** 2026-08-03

**Audience:** Harc maintainers and coding agents

**Architecture:** [Host/client architecture](../architecture/host-client-architecture.md)

**Delivery plan:** [Host/client/mobile buildout](../plans/2026-08-02-host-client-mobile-buildout.md)

## 1. Purpose and precedence

This document is the normative handoff for building HarcMobile and adopted Mac
clients around a user-controlled Harc host. It converts the approved architecture
into implementation boundaries, security contracts, state machines, acceptance
criteria, and an ordered pull-request plan.

The words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative. When this
spec conflicts with the higher-level architecture or delivery plan, this spec
wins until all three documents are reconciled in the same change.

The implementation is deliberately incremental. Every pull request MUST leave
the existing standalone Mac application buildable and releasable.

## 2. Product outcome

The first useful mobile beta, comprising the local-network alpha and library
slice in PRs 0 through 8, is complete when a fresh iPhone can:

1. record a durable local master after an explicit user action;
2. continue recording through ordinary lock and background transitions;
3. pair with a locally approved Harc host by scanning a QR ticket;
4. retain recordings while the host or network is unavailable;
5. transfer losslessly compressed, independently verifiable audio;
6. reconcile duplicate or interrupted delivery without duplicate recordings;
7. store a signed host receipt proving that canonical audio is durable;
8. show host processing status without blocking audio safety; and
9. reopen the committed recording from the permitted mobile library.

The corresponding Mac client outcome is local capture and edge processing with
the same durable outbox, identity, provenance, and host-commit rules.

## 3. Approved product rules

- Harc MUST NOT send audio, transcripts, embeddings, or summaries to a
  third-party or Harc-operated cloud processing service.
- The user's authenticated adopted host is the only automatic Harc-managed
  off-device synchronization or processing path.
- A foreground, explicit user export MAY send one selected local recording to a
  user-chosen system share/export destination. Before handing bytes to the
  system, Harc MUST disclose that the destination is outside the adopted-host
  trust boundary. It MUST NOT preselect a cloud provider, export unattended, or
  treat an export as synchronization.
- Local recording MUST never depend on host or network availability.
- The client MUST retain its last durable audio copy until it persistently stores
  a verified `RecordingReceipt` from the host.
- The host MUST be the only writer of its canonical library database and its
  portable WAV, JSON, and OKF projections.
- A capable Mac client SHOULD process its own recording locally for latency,
  offline use, and model-cache reuse.
- Signed client provenance proves who submitted an artifact; it MUST NOT be
  treated as remote attestation that a claimed model actually ran.
- A network, codec, speech, diarization, or summarization failure MUST remain
  visible and recoverable. It MUST NOT become a silent transcript or audio hole.

## 4. V1 scope and explicit non-goals

### 4.1 V1 includes

- One remembered host per client.
- A host server embedded in the existing resident Harc menu-bar process.
- QR pairing with local host approval and per-device revocation.
- Bonjour discovery on the local network.
- Active gRPC Swift 2 control and chunk transfer.
- System-managed background HTTPS upload for immutable file-backed batches.
- Mobile microphone capture, recovery, outbox, transfer status, recent library,
  transcript detail, playback, and narrowly scoped metadata mutation.
- Desktop Client mode using the existing local `harc-stt` daemon.
- Optional reachability through an independently installed Tailscale or
  user-managed VPN after local-network behavior is proven.

### 4.2 V1 does not include

- A Harc-operated relay or account service.
- Public-port onboarding.
- Remote `host.admin` operations.
- Transparent host-authority key migration or multi-host write replication.
- Multiple active canonical hosts for one library.

The separately approved [Harc Remote relay specification](2026-08-08-harc-remote-relay-spec.md)
adds an optional blind reachability relay without changing V1's single canonical
Host, application authorization, private inference, or durable capture rules.
The base V1 remains fully functional without that service.
- A host process that survives the user choosing Quit Harc.
- iOS system-audio or phone-call audio capture.
- Cloud STT, cloud diarization, cloud summarization, or external telemetry.
- Shared-worker processing of other devices' audio.
- In-process mobile inference as a release dependency.

## 5. Runtime roles and process ownership

### 5.1 Standalone Mac

The existing application remains unchanged from the user's perspective. Capture,
the `harc-stt` daemon, `RecordingStore`, search, and portable projections run on
one Mac. No host networking is required.

### 5.2 Host Mac

V1 starts `HarcHost` and its transport adapters inside the existing `LSUIElement`
menu-bar process when Host mode is enabled. Closing every window MUST leave the
host reachable. Launch at login continues to use `SMAppService.mainApp`.

The process owns exactly one `RecordingStore`, one host-state store, one OKF
projection path, and one processing scheduler. If the user quits Harc or the Mac
sleeps, the host is offline and clients queue honestly.

The currently bundled `harc-mcp` opens `Harc.db` directly and can mutate it while
the app is closed. That remains a Standalone-mode compatibility path only. Before
Host mode can be enabled, `harc-mcp` mutations and reads MUST route through a
same-UID, code-signing-validated local IPC adapter owned by the resident Harc
process. If Host mode is enabled but that process is unavailable, MCP mutation
requests fail explicitly; they MUST NOT fall back to direct database access.
This closes the second-writer and missed-change-log race.

All processes coordinate through one POSIX advisory `flock` file at the resolved
canonical database URL plus `.writer.lock`. The parent and file are owned by the
current user, the file is `0600`, and symlinks are rejected. Every Standalone
store-mediated mutation—including its database transaction, JSON/OKF projection,
and change notification—takes the exclusive lock, re-reads canonical writer mode
while holding it, and writes only if the mode is still Standalone. A long-lived
`harc-mcp` repeats that decision for every request: direct reads hold a shared
lock through the complete read, direct mutations hold the exclusive lock through
the complete mutation/projection, and both re-read mode after acquisition. A
failed nonblocking lock or Host marker routes the request to local IPC and never
to a direct store. Host's lifetime exclusive lock therefore also excludes a
read-path mode-check/open race.

To enable Host mode, the resident app waits for the exclusive lock, rechecks
Standalone mode, transactionally records writer mode, `HostAuthorityID`, and
random `HostStateID` in canonical metadata, and retains the same lock for the
entire Host-mode lifetime. Only then does it start the local adapter and network
listeners. `HarcHost.db` stores the same library/authority/state tuple. To
disable, it stops advertisement, drains host work, writes Standalone mode while
still holding the lock, and only then releases it. Process death releases the OS
lock but leaves the Host marker, so a direct writer still fails closed until the
resident host recovers or the explicit recovery flow runs. The lock is
coordination, not a security boundary, and integration tests exercise process
death and a long-lived MCP at each transition.

A future per-user `SMAppService.agent` MAY provide stronger availability, but it
must become the sole library/OKF writer and the Mac UI must use local authenticated
IPC. The app and helper MUST NOT concurrently own canonical writes.

### 5.3 Client Mac

A client Mac captures microphone and system audio locally, keeps a durable
outbox, and continues using its existing `harc-stt` daemon. It MAY submit signed
processing artifacts with full provenance. It never opens the host database.

Changing a populated installation to Client mode never merges, uploads, moves,
or deletes its existing library implicitly. V1 preserves that library under a
clearly separate **On This Mac** source with its own `LibraryID`; adopted-host
cache data stays in `HarcClientStore`. New captures in Client mode default to the
host outbox. Switching roles requires an explicit confirmation describing the
two sources. Bulk migration of the old local library is a separate future flow.

### 5.4 HarcMobile

HarcMobile captures microphone audio, owns its uncommitted masters, maintains a
client cache and outbox, and uses host-first processing initially. It MUST remain
useful without a host by allowing recovery, playback, and the explicit,
destination-disclosed user export defined in Section 3 for its own recordings.

## 6. Repository and target boundaries

Targets are activated only when a tested vertical slice needs them. Placeholder
directories remain documentation-only and MUST NOT perturb the current build.

| Target | Responsibility | Must not own |
| --- | --- | --- |
| `HarcCore` | Existing portable value types and current shared contracts | Networking or host policy |
| `HarcDomain` | Stable public IDs, revisions, processing states, discontinuities, capability-neutral domain values | Protobuf, GRDB, Keychain, UI |
| `HarcIdentity` | Key abstractions, IDs derived from keys, grants, canonical signing bytes, signatures and verification | Protobuf DTOs, manifests, transport |
| `HarcTransfer` | Domain manifests, contiguous chunks, upload/outbox state machines, receipt domain values | gRPC, URLSession, host store |
| `HarcProtocolWire` | Protobuf-generated DTOs and gRPC service stubs | Handwritten business or conversion logic |
| `HarcProtocol` | Validated domain conversions, service APIs, version/capability policy | Business state, GRDB, UI |
| `HarcHost` | Transport-independent authorization, staging, commit, recovery, library and processing application services | NIO, Bonjour, SwiftUI |
| `HarcHostTransport` | gRPC server, HTTPS upload endpoint, Bonjour advertisement, transport interceptors, authenticated local MCP IPC | Canonical business decisions |
| `HarcClientTransport` | gRPC client, HTTPS/background adapters, discovery and connection state | Client persistence or UI |
| `HarcRemoteTransport` | Shared, content-blind outer WebSocket tunnel and relay reachability material used by Host and Client adapters | Harc authority, inner TLS, canonical host policy, persistence or UI |
| `HarcClientStore` | Mobile/desktop cache, change cursor, mutation outbox, upload outbox, receipt persistence | Canonical host state |
| `HarcAudioMobile` | iOS audio-session lifecycle, capture, protected master writer and discontinuities | Host networking and STT |
| `HarcAudioMac` | Future macOS capture adapters after tested extraction | Mobile behavior |
| `HarcInference` | Future reusable FluidAudio pipeline | Transport or application UI |

Existing `HarcAudio`, `HarcClient`, `HarcStore`, and `HarcSTT` remain macOS
authoritative until behavior moves through focused tests. The first mobile slice
MUST NOT make those existing targets compile for iOS merely to create symmetric
folders.

Dependency direction is fixed (right side means “depends on”):

| Target | Direct internal dependencies |
| --- | --- |
| `HarcDomain` | None; Foundation-only portable values |
| `HarcIdentity` | `HarcDomain` |
| `HarcTransfer` | `HarcDomain`, `HarcIdentity` |
| `HarcProtocolWire` | External gRPC/SwiftProtobuf runtimes only |
| `HarcProtocol` | `HarcProtocolWire`, `HarcDomain`, `HarcIdentity`, `HarcTransfer` |
| `HarcClientStore` | `HarcDomain`, `HarcTransfer`, existing GRDB product |
| `HarcHost` | `HarcDomain`, `HarcIdentity`, `HarcTransfer`, `HarcStore`, existing daemon client adapter |
| `HarcRemoteTransport` | `HarcDomain`, `HarcProtocol` plus platform networking runtimes |
| `HarcHostTransport` | `HarcHost`, `HarcIdentity`, `HarcProtocol`, `HarcRemoteTransport` plus transport runtimes |
| `HarcClientTransport` | `HarcProtocol`, `HarcIdentity`, `HarcTransfer`, `HarcRemoteTransport` plus transport runtimes |
| `HarcAudioMobile` | `HarcDomain`, AVFAudio/Foundation |

The application targets compose stores, transports, audio, and UI. No lower
target depends on an application or transport adapter.

`HarcIdentity` MUST NOT own protobuf command envelopes or transfer manifests.
`HarcTransfer` MUST NOT import gRPC. `HarcHost` MUST expose one set of
application services used identically by gRPC, HTTPS, and loopback tests.
Mandatory MCP local IPC receives a least-privilege facade over only the methods
enumerated in Section 22; it is not an administrative projection of the whole
service set.

## 7. Stable identifiers and public data contract

The network contract MUST NOT expose host-local database row IDs or filesystem
paths as public identity.

| Identifier | Form | Authority and lifetime |
| --- | --- | --- |
| `LibraryID` | Random UUID | Created once by the canonical library; survives addresses and certificates |
| `HostAuthorityID` | SHA-256 of versioned canonical authority public key | Identifies one host authority; changes on v1 host migration |
| `DeviceID` | SHA-256 of versioned canonical device public key | Unique per installation/key; key loss requires re-pairing |
| `GrantID` | Random UUID | One current grant for a paired device |
| `OriginRecordingID` | `(DeviceID, UUID)` | Device-generated, immutable remote-ingest idempotency key |
| `CanonicalRecordingID` | Random UUID | Host-generated stable recording identity exposed to clients |
| `UploadID` | Random UUID | One resumable upload attempt, linked to an origin recording |
| `OperationID` | Random UUID | Idempotency and replay identity for one durable command |
| `ChangeCursor` | Host-monotonic unsigned integer | Orders cacheable library changes and tombstones |

The existing `Recording.id: Int64` remains an internal database primary key.
The next Harc database migration MUST run atomically and add, at minimum:

- one `library_metadata` row containing a random `LibraryID`, current writer
  mode, nullable `host_authority_id`, and nullable `host_state_id`, created
  exactly once on fresh install or upgrade; IDs are null until first Host setup,
  remain as dormant consistency markers when Host mode is normally disabled,
  change only in the OS-authenticated replacement transaction, and are cleared
  on a verified migration import before the destination creates its new tuple;
  `LibraryID` is retained across migration while writer mode resets to
  standalone until the destination explicitly enables Host mode;
- `canonical_uuid`, unique and non-null for every row;
- `origin_device_id` and `origin_recording_uuid`, unique as a pair when present;
- `canonical_pcm_sha256`;
- `revision`, non-null and monotonically increasing from one;
- `processing_state` and optional failure detail; and
- a library change log containing cursor, entity ID, revision, operation type,
  timestamp, and tombstone state.

The migration assigns and persists a random UUID plus revision one for every
legacy recording before enforcing non-null/unique constraints. It does not use a
path-derived public ID. Legacy PCM hashes may be populated by a bounded
background backfill, but a row cannot serve canonical audio or participate in
edge-artifact verification until its hash exists. Initial clients obtain every
legacy row through Section 19's anchored snapshot; an empty new change log does
not make the old library invisible.

Legacy path-based upsert remains supported for standalone filesystem ingestion,
but remote ingest MUST use the origin identity and canonical PCM hash.

All network mutation DTOs MUST use `CanonicalRecordingID` plus
`expected_revision`. Absolute `wavPath`, `txtPath`, `jsonPath`, and transcript
`audioPath` MUST never cross the network. The host rewrites portable JSON and OKF
resources to its canonical paths.

## 8. Persistence boundaries

### 8.1 Canonical library

`Harc.db` remains the authoritative coordinated library state. WAV, structured
JSON, and OKF Markdown are user-owned portable artifacts/projections. Store-
mediated mutations MUST continue to regenerate those projections. `LibraryID`
is canonical library metadata in this database, not host-transport state.

### 8.2 Host state

`HarcHost.db` is owned only by the host process and contains:

- host metadata excluding private keys, including listener ports, signed
  transport-set epochs, and leaf-retirement floors;
- paired devices, grants, scopes, epochs, revocations, monotonic registry
  revision, and pending security-mutation journal;
- pairing tickets and attempts;
- upload sessions, chunks, batches, reservations, and commit journal;
- processed operation IDs and original results;
- signed manifest and receipt bytes; and
- security audit events without content or secrets.

Private keys remain in Keychain. Staged files live under an application-support
directory generated by the host; no client-provided path component is accepted.

Because canonical files, `Harc.db`, and `HarcHost.db` cannot share one filesystem
transaction, host ingest MUST use an explicit restart-idempotent journal. Unique
origin IDs in `Harc.db` make replay after a crash safe.

### 8.3 Client state

`HarcClientStore` is a module owning two physically separate SQLite databases:

- `HarcTransferStore.sqlite` owns upload/outbox rows, minimal recording IDs and
  status, background-task mappings, exact manifests/receipts, cleanup intents,
  transfer conflicts, the active `LibraryID`/`HostAuthorityID` and authority
  public key, the exact highest signed transport set/epoch, and the current exact
  signed grant/epoch/status. Each batch row also stores the exact opaque upload
  credential plus its capability bindings and expiry. It contains no transcript,
  summary, speaker text, or general library cache and remains accessible after
  first unlock for background completion and TLS/ACK validation.
- `HarcLibraryCache.sqlite` owns permitted cached records/content, the latest
  change cursor, tombstones, offline metadata mutations, and visible library
  conflicts. It is unavailable whenever complete file protection is active.

Each database, including its WAL/SHM sidecars, has the Section 14 protection and
backup policy. Neither database reuses or mirrors the host's `HarcStore` schema.
Pairing/re-adoption replaces the active trust tuple and grant in one transaction;
transport-set updates replace exact bytes only at a higher verified epoch, while
grant changes replace exact bytes only at the next registry epoch. Historical
tuples remain nonauthorizing history.

## 9. Identity and cryptographic profile

### 9.1 Keys

- V1 MUST use P-256 ECDSA with SHA-256 for host and device signatures.
- Public keys MUST use SEC1 uncompressed X9.63 representation.
- `HostAuthorityID` and `DeviceID` are
  `SHA256("harc-p256-x963-v1\0" || publicKeyX963)`.
- The host authority signing key and TLS server key MUST be separate.
- Host and device signing keys SHOULD use Secure Enclave when available without
  user-presence access control. Simulator or unsupported hardware uses a
  Keychain-backed software P-256 key.
- Noninteractive key references MUST use a non-synchronizing,
  this-device-only, after-first-unlock accessibility class.
- The host key record also stores nonsecret `HostStateID`, highest issued
  transport-set epoch, and security-registry high-water revision. The host
  advances the transport Keychain mark before a new set can be published; the
  restart journal reconciles a DB lag but never permits a DB epoch below it.
- Pairing approval, grant issuance/replacement, scope change, revocation, and
  same-key/lost-key replacement use a three-phase security journal: durably write
  the exact pending mutation at revision N+1 in `HarcHost.db`, advance the
  Keychain registry mark to N+1, then apply the mutation and current revision in
  one HostDB transaction. On restart, an exact pending row may finish the one-step
  lag; any other DB/Keychain revision mismatch fails closed. This prevents an old
  HostDB restore from reviving authorization state that predates a revocation.
- Private keys MUST never be exported, synchronized, placed in a QR ticket, or
  copied during v1 migration.

Every installation loads or creates its device signing key before the first
recording, independently of host adoption. This makes `DeviceID` and every
`OriginRecordingID` stable for host-neutral local capture. Pairing registers the
existing installation identity; it is not the event that creates it.

Every formula in this specification written as `SHA256(domain || bytes)` and
then signed produces the one 32-byte ECDSA prehash. Implementations MUST pass
that digest to a P-256 primitive that signs a precomputed digest exactly once;
they MUST NOT pass it to a `Data` overload that applies SHA-256 again. The
CryptoKit adapter therefore uses the digest-signing overload (or an equivalent
reviewed primitive), and independently generated golden vectors detect accidental
double hashing. The same rule applies to pairing, session, envelope, and every
future registered proof signature.

Algorithm negotiation is allowed only after authenticated connection setup and
MUST fail closed. V1 implementations advertise only this profile.

### 9.2 Host transport set and anti-rollback

The stable host authority signs an exact `HostTransportSetV1` payload with this
encoding, independently of protobuf:

```text
magic                    8 bytes  "HARCTS1\0"
protocol_major           u16 big-endian
protocol_minor           u16 big-endian
library_id               16 raw UUID bytes
host_authority_id        32 bytes
set_epoch                u64 big-endian
issued_at_unix_ms         u64 big-endian
entry_count              u8, value 1 or 2
entries                  sorted by SPKI hash, each:
  tls_spki_sha256         32 bytes
  not_before_unix_ms      u64 big-endian
  not_after_unix_ms       u64 big-endian
```

It is signed through `HarcSignedEnvelopeV1` with message type
`host.transport.set.v1`. An entry may span at most 90 days. Verification permits
at most five minutes of clock skew at a validity boundary and never accepts an
expired entry beyond that tolerance. Golden vectors pin payload, envelope, and
signature bytes.

The pairing QR carries the exact signed set and authority public key. A client
stores the highest verified `set_epoch` keyed by the exact
`(LibraryID, HostAuthorityID)` tuple and rejects every lower epoch for that tuple
even if its signature and time window remain valid. A different authority for a
migrated library starts a separate trust namespace and may begin at epoch one;
epochs are never compared across authorities. It accepts TLS only when the
observed SPKI appears in the highest set for the actively adopted tuple with a
valid interval.

Rotation publishes epoch N+1 containing old and new SPKIs before the new leaf is
served, then epoch N+2 containing only the new SPKI. `MintBackgroundCapability`
returns the exact current signed set; the client MUST verify and durably persist
that set before scheduling the file. The set MUST contain at least one leaf whose
certificate and transport-set entry remain valid through the requested
capability expiry plus five minutes. If not, the host first rotates/publishes a
covering set, clamps the capability expiry with an explicit result, or rejects
minting; it never issues a credential that cannot remain pin-valid. A normal
cutover cannot retire the old leaf
until every unexpired capability minted before its client stored N+1 has expired,
plus the five-minute clock tolerance. Thus the effective overlap is at least the
maximum remaining capability lifetime and can approach 30 days. The host tracks
that retirement floor in `HarcHost.db`; an operator cannot bypass it silently.
Once a client sees a set, it never rolls back.

Every served Harc leaf carries the exact current framed signed
`HostTransportSetV1` object in one noncritical X.509 extension with OID
`2.25.148088663479842491025708621331721812820` (the `2.25` UUID-derived arc for
`6f68d6d2-02c7-4a66-aee9-0b4b7d2efb54`). The extension's DER `extnValue`
contains the signed-object bytes directly after the standard OCTET STRING unwrap,
is at most 4 KiB, and may appear only once. A new leaf embeds the covering N+1
set before it is served. This gives a client that was offline through
prepublication an authority-authenticated update during certificate trust
evaluation, before application data or `GetHostInfo` is accepted.

Emergency retirement may publish the next epoch containing only the replacement
key and deliberately invalidate outstanding background tasks. A client that was
offline and never received that epoch cannot learn emergency revocation from an
attacker replaying a still-valid old set; the host MUST mark affected devices as
requiring trust repair or re-pairing. This limitation and the invalidated uploads
are shown in the host UI rather than disguised as global online revocation.

TLS leaf rotation MUST NOT change the library or host-authority identity.
Unauthenticated Bonjour, DNS, IP, hostname, and VPN information never changes
the pinned authority or highest transport-set epoch.

### 9.3 TLS profile

The host generates a self-signed P-256 server certificate whose private key is
separate from the authority key. It has a random serial, server-auth extended
key usage, digital-signature key usage, and a validity period no longer than its
transport-set entry. ALPN is listener configuration, not certificate content:
the gRPC TLS listener advertises and requires `h2`, while the upload TLS listener
advertises and requires `http/1.1`. V1 requires TLS 1.3.

Client trust handling parses certificate validity and key usage, extracts the
SPKI and the extension above, and verifies the embedded object with the already
pinned host-authority public key for the active `LibraryID`. A lower epoch is
rejected; an equal epoch must be byte-identical to the stored set; a higher epoch
is durably committed to `HarcTransferStore` before the trust callback accepts
the connection. The observed SPKI must appear in that resulting highest set with
a currently valid interval, and the extension/certificate validity and key usage
must pass. A missing, duplicate, oversized, malformed, wrongly signed, or
equivocating extension fails closed.

For gRPC, accepted trust is attached to the physical TCP/TLS channel before the
certificate-verification promise succeeds. Each HTTP/2 stream copies trust only
from its exact parent connection. A client pipeline handler strips all
peer-supplied copies of a reserved binary response-binding header and injects a
fresh client-owned trust envelope on initial response headers. The envelope has
a 256-bit nonce and is authenticated with HMAC-SHA256 under a 256-bit key owned
only by that `HarcPinnedGRPCConnection`. The generated-client adapter verifies
the HMAC, reparses the exact leaf certificate, re-verifies its embedded
authority-signed transport set, requires SPKI/validity coverage, and reconstructs
the accepted trust before returning a successful bootstrap response. Missing,
duplicate, malformed, unauthenticated, or semantically inconsistent bindings
fail closed. Trailers-only failures receive no binding, and there is no global
or "latest handshake" fallback. The envelope codec is stateless: abandoned,
cancelled, or retried streams consume no registry capacity or cleanup state.
Fresh nonces make envelopes distinct but do not claim local replay prevention.
The construction preserves each stream's parent-connection association during
DNS replacement or TLS rotation; physical overlapping A/B validation remains a
release gate for future multi-address connection racing.

DNS name, IP SAN, system-root trust, or a user-added
root never substitutes for the pin. Because addresses are reachability hints,
hostname mismatch alone is not the identity decision after exact SPKI
verification. A pin/time/key-usage failure has no insecure fallback and becomes
an actionable security state. Both gRPC TransportServices and background
URLSession use golden certificate fixtures plus physical rotation/mismatch tests.

### 9.4 Trust model

The host is fully trusted for its library. The network is hostile. Each adopted
client is potentially compromised and MUST be limited by current server-side
scope, quota, epoch, and object ownership checks.

### 9.5 Device grant payload

The exact `DeviceGrantV1` payload contains protocol version, `LibraryID`, host
authority ID, grant ID, device ID, full device public key in X9.63 form and its
hash, sorted scopes, grant epoch, issued time, optional expiry, and the
minimum/maximum compatible protocol
minor. The host signs its exact protobuf bytes through `HarcSignedEnvelopeV1`
with message type `identity.device-grant.v1` and persists those bytes.

The payload, envelope, and signature have golden fixtures. A grant proves what
the host issued; current registry state remains authoritative and can narrow or
revoke it at any time.

`DeviceRevocationV1` contains protocol version, `LibraryID`, host authority ID,
device ID, grant ID, prior and new grant epochs, revocation ID, local reason
code, and `issued_at_unix_ms`, which is also its immediate effective time. The
host persists and signs its exact bytes with message type
`identity.device-revocation.v1` in the same transaction that advances registry
state. Scope change preserves the grant ID and issues a replacement
`DeviceGrantV1` at the next epoch.

## 10. Pairing protocol

Pairing begins only from a foreground local host UI and remains open for at most
two minutes.

### 10.1 Ticket and QR encoding

The QR payload is exactly one ASCII URI:

```text
harc-pair://v1/<base64url-without-padding(PairingTicketV1 bytes)>
```

It has no user info, query, fragment, percent encoding, padding, or surrounding
whitespace. It uses QR Code Model 2 error correction Q and is at most 1,400 ASCII
bytes. The decoded binary is at most 1,024 bytes and has this canonical encoding:

```text
magic                    9 bytes  "HARCTKT1\0"
total_length             u16 big-endian, entire binary including this header
protocol_major           u16 big-endian
protocol_minor           u16 big-endian
ticket_id                16 raw UUID bytes
library_id               16 raw UUID bytes
host_authority_id        32 bytes
host_public_key_x963     65 bytes
transport_object_length  u16 big-endian, 1...768
transport_object         exact framed signed HostTransportSetV1 object
ticket_secret            24 random bytes
issued_at_unix_ms         u64 big-endian
expires_at_unix_ms        u64 big-endian
endpoint_count           u8, 0...4
endpoints                 sorted; each:
  kind                    u8: 1 Bonjour instance, 2 DNS host, 3 IPv4, 4 IPv6,
                          5 remote relay
  port                    u16 big-endian; zero only for a Bonjour instance
  value_length            u8, 1...255
  value                   exact kind-specific bytes
```

Text is NFC UTF-8 without NUL/control characters; DNS is a lowercase A-label
without a trailing dot. Endpoints are unique and sorted by kind, value bytes,
then port. IPv4 and IPv6 value lengths are exactly four and sixteen; text kinds
use the stated one-to-255-byte bound. A remote-relay value is its versioned
canonical HTTPS-host and three-independent-256-bit-opaque-value encoding from
the Harc Remote contract and always uses port 443. Base64url uses the RFC 4648
URL alphabet and shortest canonical form.
Unknown version/kind, wrong key/ID derivation, length mismatch, duplicate,
noncanonical order/text, invalid signed transport object, expired ticket, expiry
more than two minutes after issue, or trailing byte is rejected before network
use. Endpoints remain reachability hints rather than Host identities; direct
hints are authenticated only by the pinned TLS connection, while any ticket
containing a Remote hint also commits its complete canonical bytes into pairing
admission as specified below. The displayed host fingerprint is derived from
`host_authority_id`; it is not a second QR field.

Golden fixtures pin the binary ticket, URI, QR round trip, maximum-size case,
authority/transport binding, and one-bit/length/order/base64/tamper rejections.

The host retains the raw ticket in the foreground pairing controller long
enough to render. Harc never automatically copies it to pasteboard, logs,
diagnostics, analytics, disk, backup, or any relay. For Mac-to-Mac adoption, the
user MAY explicitly export the exact URI as a canonical `.harcpair` invitation.
That file is created with current-user-only permissions, contains no additional
identity or authority, and retains the ticket's original two-minute expiry. The
Client reads only a bounded regular file without following symlinks, validates
the complete canonical ticket before network use, presents the Host address,
authority fingerprint, and expiry for confirmation, and retains the raw ticket
only through claim establishment. Harc provides no cloud transfer service;
moving the invitation through email, messaging, a cloud drive, or a shared
clipboard is an explicit user-directed export outside Harc's trust boundary.

For a direct-only ticket, `pairing_admission_secret` is the raw 24-byte
`ticket_secret`, preserving the frozen V1 direct-pairing behavior. If any
remote-relay endpoint is present, the client and issuing Host instead derive:

```text
pairing_admission_secret = first 24 bytes of
SHA256("HARC-PAIRING-REMOTE-ADMISSION-V1\0" || exact_pairing_ticket_bytes)
```

This commits the admission bearer to every canonical invitation byte. Adding,
removing, or changing a relay endpoint therefore produces a different bearer
that cannot match the Host's original reservation. The host persists only the
value named `ticket_secret_binding_sha256`:

```text
SHA256("HARC-PAIRING-TICKET-SECRET-V1\0" || ticket_id_bytes ||
       pairing_admission_secret)
```

Ticket state is one of `issued`,
`reserved`, `approved`, `consumed`, `expired`, or `cancelled`, and transitions
are atomic. Only one applicant may reserve a ticket. Approval, expiry,
cancellation, signature mismatch, or verification mismatch makes it permanently
unusable.

V1 ships QR adoption and an explicit file rendering of the identical canonical
high-entropy ticket for Mac-to-Mac transfer. It does not ship a short numeric
bearer code. Any future human-entered fallback requires either a separately
authenticated high-entropy payload that binds the host authority or a reviewed
PAKE such as SPAKE2+; it is a new security protocol, not another rendering of
this ticket.

### 10.2 Handshake

1. The client loads its installation device signing key. A clean installation
   creates it; a missing key alongside prior identity/captures enters the
   explicit key-loss policy below rather than silently generating one.
2. It connects using a ticket endpoint hint and verifies TLS through the QR-pinned
   host authority and transport set.
3. `BeginPairingClaim` sends ticket ID, the 24-byte
   `pairing_admission_secret`, a fresh 32-byte client nonce, the device public
   key, and sorted requested scopes. For a Remote ticket the raw invitation
   seed is never sent; both values remain ephemeral and are never logged or
   stored.
4. The host recomputes and constant-time compares the stored secret hash, checks
   expiry and rate limits, atomically reserves the ticket for that device, and
   creates a claim ID, fresh 32-byte host nonce, and 32-byte opaque claimant
   token. It stores only
   `SHA256("HARC-PAIRING-CLAIM-TOKEN-V1\0" || claim_id || token)` and returns
   the token once.
5. The client constructs and signs the exact transcript below, then sends it to
   `ProvePairingClaim` with the claim ID and claimant token.
6. The host reconstructs the transcript from reserved server state, verifies the
   device signature, and permanently cancels the ticket on any mismatch.
7. Both peers derive the same four-word short authentication string from the
   first 44 bits of the SAS digest below using the versioned 2,048-word list.
8. The host UI shows the device label, fingerprint, requested scopes, and phrase;
   the client shows the same phrase.
9. The user confirms the phrase and approves exact scopes locally. Broader
   initial scopes follow Section 12's OS-authentication rule.
10. The host atomically consumes the ticket, creates the registry entry and
    signed `DeviceGrantV1`, and makes the exact grant bytes available through
    `GetPairingStatus`.
11. Both peers persist the result before reporting success.

If the presented `DeviceID` already has a registry entry, pairing is a visible
same-key re-adoption rather than a duplicate device. It requires local OS
authentication; approval preserves the device ID, advances the existing grant
to the next epoch (or replaces a revoked grant under an explicit new grant ID),
issues new exact grant bytes, and atomically invalidates all old sessions and
capabilities. This covers reinstall when a ThisDeviceOnly Keychain item survives
but client databases do not.

If the device key is gone, an explicit local key-loss recovery with OS
authentication creates a new installation identity for future captures and
pairing. Existing `FinalizedCapture` records retain their old producing
`DeviceID`/origin and MUST NOT be re-attributed or host-uploaded under the new
key in V1; they remain locally recoverable, playable, and explicitly exportable.
A future re-attribution protocol requires its own provenance/security spec.

For the new identity, the host UI offers an explicit **Replace lost device**
choice that, with OS authentication, revokes the selected old device and creates
the new registry entry in one transaction. Labels alone never trigger
replacement, and adding the new device without replacement leaves two
separately visible/revocable entries.

The claimant token is sent as `Authorization: HarcPairing <opaque-token>`, is
bound to the claim ID, ticket ID, and device ID, and expires with the ticket.
`GetPairingStatus` requires that token and pinned TLS. It exposes only pending,
approved with exact grant bytes, denied, expired, or cancelled for that claim.

### 10.3 Canonical pairing proof

`PairingTranscriptV1` is encoded independently of protobuf:

```text
magic                    10 bytes  "HARCPAIR1\0"
protocol_major           u16 big-endian
protocol_minor           u16 big-endian
ticket_id                16 raw UUID bytes
claim_id                 16 raw UUID bytes
library_id               16 raw UUID bytes
host_authority_id        32 bytes
host_public_key_x963     65 bytes
tls_spki_sha256          32 bytes
device_id                32 bytes
device_public_key_x963   65 bytes
client_nonce             32 bytes
host_nonce               32 bytes
ticket_secret_binding_sha256 32 bytes
requested_scope_count    u8, at most 8
requested_scopes         sorted; each u16 length + registered ASCII scope
```

The client signature input is:

```text
SHA256("HARC-PAIRING-CLIENT-PROOF-V1\0" || transcript_bytes)
```

The SAS source is:

```text
SHA256("HARC-PAIRING-SAS-V1\0" || transcript_bytes || client_signature_raw)
```

`ticket_secret_binding_sha256` is exactly the domain-separated value persisted
in Section 10.1, not `SHA256(secret)`. The client computes it from the derived
admission secret and ticket ID; the host copies its persisted value into the
transcript, so every Remote endpoint byte is indirectly covered by the device
signature and SAS and neither side needs the admission secret after claim
reservation.

The SAS dictionary is the checked-in UTF-8/LF file
`Protos/Fixtures/harc-sas-words-v1.txt`. It contains exactly 2,048 unique,
lowercase ASCII entries in zero-based protocol order and has SHA-256
`2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
It is vendored from the BIP-39 English list, but Harc uses it only as a
short-authentication dictionary, not as a cryptocurrency mnemonic. A verifier
MUST reject a resource with a different byte hash.

Treat the SAS digest as a big-endian bit string. The displayed words are the
zero-based dictionary entries selected by consecutive bits `[0...10]`,
`[11...21]`, `[22...32]`, and `[33...43]`; no modulo or machine-endian integer
conversion is permitted. Display them in that order separated by one space.
Golden fixtures pin ticket hashing, transcript bytes, proof digest, raw low-S
signature, SAS digest, all four indexes, and displayed words. Nonces, claim IDs,
claimant tokens, and reservations are single-use. A claim may not change its
device key or scope request after reservation.

Ticket possession alone never authorizes a client. Pairing approval, scope
elevation, revocation, and host migration are local control-plane operations and
MUST NOT be exposed as remote v1 RPCs.

## 11. Signed envelope

Harc MUST NOT verify a signature by decoding and reserializing protobuf. Durable
objects sign a stable envelope plus the SHA-256 of the exact transmitted payload
bytes.

### 11.1 Canonical header encoding

`HarcSignedEnvelopeV1` is encoded independently of SwiftProtobuf:

```text
magic                    8 bytes  "HARCSE1\0"
message_type             u16 length + UTF-8 ASCII enum
protocol_major           u16 big-endian
protocol_minor           u16 big-endian
library_id               16 raw UUID bytes
host_authority_id        32 bytes
signer_device_id         32 bytes, all zero for a host signature
grant_id                 16 raw UUID bytes, all zero when not applicable
grant_epoch              u64 big-endian
operation_id             16 raw UUID bytes
issued_at_unix_ms         u64 big-endian
expires_at_unix_ms       u64 big-endian, zero when not applicable
payload_type             u16 length + UTF-8 ASCII enum
expected_revision        u64 big-endian, UInt64.max when not applicable
payload_sha256           32 bytes
```

Strings are restricted to registered ASCII enumerations. UUIDs use RFC 4122 byte
order. The signing input is:

```text
SHA256("HARC-SIGNED-ENVELOPE-V1\0" || canonical_header_bytes)
```

P-256 signatures use the 64-byte raw `r || s` representation. Signers MUST
normalize `s` to the lower half of the P-256 group order and verifiers MUST
reject high-S signatures. Golden fixtures MUST pin public key, header bytes,
payload bytes, digest, signature, high-S rejection, and negative tamper cases
across releases.

An exact signed object is framed for persistence and identity as:

```text
magic                    8 bytes  "HARCSO1\0"
header_length            u32 big-endian
canonical_header         header_length bytes
payload_length           u64 big-endian
exact_payload            payload_length bytes
signature_length         u16 big-endian, value 64 in V1
signature                signature_length bytes
```

Its stable identity is:

```text
SHA256("HARC-SIGNED-OBJECT-ID-V1\0" || framed_signed_object_bytes)
```

References such as a signed manifest ID use this object identity, not merely the
decoded protobuf or payload hash.

### 11.2 Registered signed objects

Every V1 signer and verifier MUST enforce this table before interpreting a
payload. `zero` means all-zero bytes or integer zero; `none` for expiry means
zero; `N/A` for revision means `UInt64.max`. Registered `payload_type` strings
are exact, case-sensitive ASCII values.

| `message_type` | `payload_type` | Signer | `grant_id` / `grant_epoch` | `operation_id` | Expiry | Expected revision |
| --- | --- | --- | --- | --- | --- | --- |
| `host.transport.set.v1` | `harc.v1.HostTransportSetV1` | Host authority | zero / zero | zero | none | N/A |
| `identity.device-grant.v1` | `harc.v1.DeviceGrantV1` | Host authority | mirror payload / mirror payload | zero | mirror grant expiry | N/A |
| `identity.device-revocation.v1` | `harc.v1.DeviceRevocationV1` | Host authority | mirror payload / mirror new epoch | mirror revocation ID | none | N/A |
| `transfer.recording-manifest.v1` | `harc.v1.RecordingManifestV1` | Producing device | zero / zero | mirror upload ID | none | N/A |
| `transfer.batch-ack.v1` | `harc.v1.BatchAckV1` | Host authority | zero / zero | mirror batch ID | none | N/A |
| `transfer.recording-receipt.v1` | `harc.v1.RecordingReceiptV1` | Host authority | zero / zero | mirror upload ID | none | N/A |
| `library.metadata-mutation.v1` | `harc.v1.MetadataMutationV1` | Requesting device | mirror payload / mirror payload | mirror operation ID | mirror command expiry | mirror payload |
| `processing.artifact.v1` | `harc.v1.ProcessingArtifactV1` | Producing device | mirror payload / mirror payload | mirror operation ID | mirror submission expiry | N/A |
| `migration.trust-history.v1` | `harc.v1.PortableTrustHistoryV1` | Exporting host authority | zero / zero | mirror export ID | none | N/A |

For every row, header protocol version, `LibraryID`, host authority ID,
`issued_at_unix_ms`, and every field marked `mirror` MUST equal the corresponding
payload field. `payload_sha256` MUST equal the hash of the untouched payload
bytes. A host-signature row requires an all-zero `signer_device_id`; a
device-signature row requires the payload's device ID and the registered current
public key for that device. The verifier rejects a nonzero N/A field, a
header/payload mismatch, an unregistered type pair, the wrong signer class, an
expired command at first acceptance, or a grant that is not current for a
command row. Expiry limits initial command acceptance; it does not invalidate a
historical signature on an already accepted durable object.

Historical migration verification is the sole exception to the live-registry
lookup: it uses the exact device public key and host-signed grant preserved in a
verified `PortableTrustHistoryV1` namespace. That namespace can validate old
provenance but can never satisfy live authorization or session establishment.

Payload definitions MUST contain every mirrored field named above. No generic
defaulting rule is permitted, and a new signed type requires a new table row,
golden fixture, and protocol-minor capability before release.

### 11.3 Replay rules

- The durable replay key is the exact tuple `(LibraryID, HostAuthorityID,
  message_type, signer identity, OperationID)`, where signer identity is the
  host authority for a host signature or `DeviceID` for a device signature.
  The host persists every accepted nonzero replay key and result. Different
  message types may intentionally use the same UUID (for example a manifest and
  receipt both use the upload ID) without colliding.
- An exact replay returns the original result idempotently.
- Reusing a replay key with different header or payload bytes is rejected and
  audited. Rows whose registered operation ID is zero use their signed-object ID
  and object-specific uniqueness rule rather than the command replay table.
- Expiry supplements persistent replay detection; it never replaces it.
- Every client-signed side-effecting command has a nonzero expiry no more than
  seven days after issue. Upload capabilities and bootstrap challenges use the
  narrower lifetimes defined in their sections.
- The host rejects a client `issued_at` more than five minutes in its future,
  an expiry at or before issue, and every command past expiry. Authenticated host
  time returned at session setup lets a skewed client repair its clock model.
- Authorization, lease, ticket, initial-command, and retention decisions use
  only the host's trusted clock. Transport and application-service callers have
  no timestamp override for those decisions; request timestamps remain signed
  data that is validated against host time.
- Mutations include `expected_revision` and fail with a typed conflict.
- TLS 1.3 0-RTT MUST be disabled for pairing, upload, mutation, administration,
  and every other side-effecting operation.
- Exact signed manifests, grants, revocations, processing artifacts, offline
  mutations, and receipts remain durably available after parsing.

## 12. Authorization and scopes

The host registry is authoritative. A self-contained signed grant is necessary
but never sufficient when current registry state says the device is revoked,
expired, or on a newer grant epoch.

Initial v1 scopes are:

- `recording.upload.own`
- `recording.read.own`
- `library.metadata.read`
- `library.transcript.read`
- `library.audio.read`
- `library.metadata.write`
- `processing.submit.own`

Caching is client policy after authorized download, so there is no
`library.audio.cache` scope. `host.admin` and general `processing.shared` are not
remote v1 scopes. Remote deletion is deferred until soft-delete, retention,
tombstone, recovery, revision, and audit behavior has its own approved contract.

The minimal mobile grant is `recording.upload.own` plus
`recording.read.own`. The minimal Mac Client grant adds
`processing.submit.own`. A foreground pairing confirmation may issue only these
minimal sets without an additional OS authentication step. Granting any
`library.*` scope during initial pairing, or adding any scope later, requires
successful local OS user authentication. The approval UI shows each scope
independently; requested does not mean granted.

Every non-bootstrap RPC, chunk, batch, and stream message checks the
authenticated session identity, current grant ID, epoch, scope, and object
ownership. Bootstrap exceptions and their narrower proofs are exhaustively
listed in Section 13.3. The host MUST NOT trust a client-supplied `DeviceID` as
the authenticated identity.

Scope change increments `grant_epoch`, invalidates old session credentials and
background capabilities, and terminates affected active streams within five
seconds. Revocation rejects new connections, queued offline mutations, current
uploads, and processing leases while leaving unrelated devices valid. Device-key
replacement is modeled as revocation followed by new pairing.

## 13. Transport and protocol implementation

### 13.1 Platform and dependency baseline

The first mobile target has a deployment floor of iOS 18. The current macOS
deployment floor remains unchanged. Harc uses the gRPC Swift 2 package family:

Mobile hardware support is deliberately two-tiered. Capture, protected durable
storage, pairing, transfer, playback, and Library access MUST NOT depend on a
specific iPhone marketing model or on-device model inference. The iOS deployment
floor controls installation eligibility; no `UIRequiredDeviceCapabilities`
entry beyond Xcode's platform-generated architecture requirement may be added to
disguise missing oldest-device qualification. Optional on-device inference MAY
use a separately measured runtime capability/performance tier, but an unavailable
tier falls back to the adopted Host and MUST NOT block or degrade durable capture.
Before release, the evidence bundle names and qualifies the oldest supported
physical iPhone; source compatibility with iOS 18 alone is not a performance or
reliability claim for every eligible device.

- `GRPCCore` from `grpc-swift-2`;
- `GRPCProtobuf` and `GRPCProtobufGenerator` from `grpc-swift-protobuf`; and
- `GRPCNIOTransportHTTP2TransportServices` from
  `grpc-swift-nio-transport` on Apple platforms.
- `SwiftProtobuf` from `swift-protobuf` as a direct runtime dependency of
  `HarcProtocolWire`; generated `.pb.swift` files import it directly even though
  the generator also depends on it.
- `NIOCore`, `NIOHTTP1`, and `NIOFoundationCompat` from `swift-nio`, plus
  `NIOTransportServices` from `swift-nio-transport-services`. `NIOCore` and
  `NIOTransportServices` support the gRPC listener/source bridge as well as the
  narrow HTTPS adapter; `NIOHTTP1` and `NIOFoundationCompat` remain specific to
  the HTTPS body edge; and
- `NIOHTTP2` and `NIOHPACK` from `swift-nio-http2` as direct dependencies of
  the server source-policy bridge and client response-to-TLS binding bridge.

The implementation PR MUST pin compatible released versions in
`Package.resolved`; branch dependencies are prohibited. The active bootstrap
edge disables gRPC message compression. Future audio methods also disable gRPC
message compression and carry independently decodable application-level
lossless chunks. Text-heavy library responses MAY enable gRPC compression after
a measurement proves a benefit.

`Protos/` is the source of truth. A generated-only `HarcProtocolWire` target
uses `GRPCProtobufGenerator` against that directory. `HarcProtocol` depends on
the wire target and owns domain conversions and compatibility policy. Generated
Swift MUST NOT be edited by hand. CI builds from a clean checkout and fails if
the schemas cannot regenerate deterministically.

#### Listener topology

PR 6 uses two process-owned TLS listeners with the same rotating TLS leaf/SPKI:

1. a gRPC HTTP/2 listener implemented by
   `GRPCNIOTransportHTTP2TransportServices`; and
2. a separate SwiftNIO HTTP/1.1 listener over `NIOTransportServices` that accepts
   only the background batch `PUT` path and bounded response types.

There is no speculative shared HTTP/gRPC multiplexer. The Bonjour service port
is the gRPC port; TXT may carry the nonsecret upload-port hint, but it is
untrusted. `HarcHost.db` persists the chosen upload port, and the host MUST
rebind that port across ordinary restart while any capability remains unexpired.
The minted URL uses the DNS-SD-resolved `.local` target hostname, never a numeric
IP literal, so DHCP address change does not stale the task. Failure to rebind is
a visible degraded Host state and prevents minting new capabilities.

After session authentication, `MintBackgroundCapability` returns the current
absolute HTTPS upload URL separately from the opaque credential. The credential
binds `LibraryID`, host authority, minimum transport-set epoch, method, path, and
body hash; it never appears in the URL. It does not bind one leaf SPKI, host
name, IP, or port, so the same exact capability/body may be safely rescheduled
after a reachability change. The background session independently requires a
currently valid SPKI in its highest transport set, whose epoch must be at least
the capability minimum.

If a host-name collision, user rename, or unavoidable port conflict changes the
URL, the terminal background-task callback or completion-event relaunch attempts
bounded Bonjour rediscovery within the system-granted execution window. It
treats target/port as candidates, verifies the
same adopted authority and transport set through pinned-TLS `GetHostInfo`, then
constructs a replacement upload URL from that resolved target and advertised
upload port. The upload connection independently repeats the SPKI check and
schedules the same immutable file/capability. Exact-body idempotency makes an
overlap safe. This bootstrap needs neither a foreground session nor a new
credential. iOS does not guarantee another wake if bounded discovery cannot
finish: Harc persists the queue and retries at the next system-granted execution
opportunity or foreground launch. It never spins or weakens trust. Until an
authenticated candidate exists, files remain queued.
Address/port changes are reachability changes and never trust changes.

### 13.2 Services

V1 defines these service surfaces:

| Service | V1 methods | Purpose |
| --- | --- | --- |
| `HostInfoService` | `GetHostInfo`, `NegotiateCapabilities` | Version, identity, codec, and feature negotiation |
| `PairingService` | `BeginPairingClaim`, `ProvePairingClaim`, `GetPairingStatus` | Ticket-bound application and locally approved grant delivery |
| `SessionService` | `BeginSession`, `OpenSession` | Device challenge-response and short-lived session establishment |
| `RecordingTransferService` | `BeginUpload`, `DeclareChunks`, `UploadChunks`, `ReconcileUpload`, `CommitUpload`, `AbandonUpload`, `GetRecordingStatus`, `MintBackgroundCapability` | Resumable audio ingest and receipt recovery |
| `LibraryService` | `BeginLibrarySnapshot`, `ListSnapshotPage`, `ListChanges`, `GetRecording`, `GetAudio`, `SearchMetadata`, `SearchTranscripts`, `ApplyMetadataMutation` | Anchored snapshot, delta sync, detail, audio, typed search, and compare-and-swap mutation |
| `ProcessingService` | client-streaming `SubmitOwnArtifact`, `GetProcessingStatus` | Provenance-bearing edge result submission and status |

Remote device administration is intentionally absent. The local host UI calls
the same host application services through in-process interfaces; it does not
open a privileged network RPC.

Protocol major versions represent incompatible semantics. Minor versions are
additive. A client MUST reject an unsupported major, an unknown required
capability, an unknown signed message type, or an unknown critical field. Proto
field numbers and enum values are never reused. Golden fixtures cover the
oldest supported minor and the current minor.

### 13.3 Connection authentication

The method-level authentication matrix is exhaustive:

| Method class | Required proof | Permitted result |
| --- | --- | --- |
| `GetHostInfo`, `NegotiateCapabilities` | No device identity; source/IP rate limit. Pairing clients additionally verify the QR-pinned transport set. | Public protocol/capability hints and exact signed transport set only; no device, library, or ticket state |
| `BeginPairingClaim` | Pinned TLS, ticket ID and secret, client nonce and device key, Section 10 limits | One claim ID, host nonce, and claimant token for that ticket/device |
| `ProvePairingClaim`, `GetPairingStatus` | Pinned TLS plus hashed claimant-token match; proof method also requires the Section 10 device signature | State and exact grant bytes for only that claim |
| `BeginSession` | Pinned TLS, active grant/device lookup, pre-auth rate limit | One short-lived challenge; no library content |
| `OpenSession` | Pinned TLS, current registry grant/epoch, and Section 13.3 device proof | One short-lived opaque session credential |
| Recording, library, and processing gRPC methods | Current session on every request/message plus method scope and ownership | Only the authorized operation/object set |
| Background batch `PUT` | Pinned TLS plus the exact Section 13.4 capability | One bound immutable batch and its signed ACK |

No other pre-session method exists. Bootstrap requests never return library
metadata, device lists, or ticket existence beyond the presented claim.
`BeginSession` has the one deliberate exception described below: a caller that
already possesses a candidate 256-bit device ID and 128-bit grant ID can
distinguish an active current grant because the host must return that exact
verifiable grant for offline scope and epoch repair.

The custom `NWListener` integration may expose `"<unknown>"` through gRPC
Swift's generic `ServerContext` peer strings. Harc never treats that placeholder
as a source identity and never falls back to one global anonymous bucket. The
HTTP/2 stream initializer instead reads the accepted `NWConnection` endpoint,
normalizes the numeric IP or canonical Unix-domain path with the ephemeral port
removed, derives an opaque host-scoped source HMAC, and replaces any
client-supplied reserved metadata with one separately authenticated internal
token before protobuf metadata decoding. Every bootstrap adapter requires and
verifies that token when generic peer strings are unavailable. Failure to
derive, inject, or authenticate it rejects the request before application
validation.

One `HarcBootstrapGRPCServiceFactoryV1` owns the host-scoped source-binding
provider and malformed-preauthentication gate for the runtime lifetime. It
constructs HostInfo, Pairing, Session, and RecordingTransfer adapters for each
served-certificate generation. Bootstrap adapters receive the same provider and
gate, the HTTP/2 source bridge receives the same provider, and the transfer
adapter receives the concrete session authenticator plus that generation's
served-identity binding. Concrete adapter construction and the raw runtime
service-array seam are internal test seams. The current production call graph
enters the runtime only through this factory and therefore cannot split source
identity, cooldown state, session authentication, or TLS generation binding.
Because Swift `internal` access is target wide, this is a reviewed composition
invariant rather than a compiler-enforced one; transport contract tests and
source review must reject any new production caller of those seams.

Post-session methods enforce this minimum scope/ownership matrix:

| Method | Scope | Additional object rule |
| --- | --- | --- |
| `BeginUpload`, `DeclareChunks`, `UploadChunks`, `ReconcileUpload`, `CommitUpload`, `AbandonUpload`, `GetRecordingStatus`, `MintBackgroundCapability` | `recording.upload.own` | Origin device and upload owner equal the session device; capability covers only already declared chunks |
| `BeginLibrarySnapshot`, `ListSnapshotPage`, `ListChanges`, `SearchMetadata` | `library.metadata.read` | Metadata search is limited to title, tags, dates, speaker labels already exposed as metadata, and typed filters |
| `SearchTranscripts` | `library.transcript.read` | Transcript/semantic query, match existence, ranking, and snippets are all transcript-protected |
| `GetRecording` for the session device's recording | `recording.read.own` | Returns own metadata/status; transcript still needs transcript scope unless it is the client's submitted artifact |
| `GetRecording` for any other recording | `library.metadata.read` | Transcript field additionally needs `library.transcript.read` |
| `GetAudio` | `recording.read.own` for own audio, otherwise `library.audio.read` | Exact canonical recording ID and current tombstone/revision checks |
| `ApplyMetadataMutation` | `library.metadata.write` | Expected revision and permitted field set |
| `SubmitOwnArtifact` | `processing.submit.own` | Origin device, recording ownership, audio hash, and complete coverage match |
| `GetProcessingStatus` | Same read rule as the target recording | No artifact content beyond granted read scopes |

The host filters each response field after authorization; possessing a recording
UUID or change cursor never broadens access.

`SearchMetadata` MUST NOT query transcript text, embeddings, summaries, or any
index derived from protected content. This prevents a metadata-only client from
inferring transcript words through match/no-match or ranking side channels.

`BeginSession` accepts a grant ID and claimed device ID only as lookup hints. If
the current registry entry is active, it creates a random challenge ID and
32-byte server nonce with a 30-second expiry. Challenges are single-use, capped
at five outstanding per device/source pair, and deleted on success, mismatch, or
expiry.

Its response also carries the current exact signed `DeviceGrantV1`, allowing an
offline client to learn a locally approved epoch/scope change. The client
verifies that host signature before constructing the transcript but receives no
authority until `OpenSession` proves its device key. Invalid or revoked lookup
hints receive the same status, response shape, nonce/challenge entropy, expiry,
and pre-proof work path, with a non-verifying dummy grant, and can never open a
session.

The exact current grant is necessarily distinguishable from dummy bytes to a
caller that already knows the host authority and both lookup hints. V1 accepts
that narrow validity signal because signing synthetic grants would create an
unsafe authority oracle, while omitting the real grant would prevent offline
scope and epoch repair. The lookup tuple's entropy, the per-device/source
challenge limit, the malformed-preauthentication cooldown, generic errors, and
aggregated audit events are the enumeration controls. Harc MUST NOT describe
this as cryptographic indistinguishability or broaden the response with any
other device state.

`SessionTranscriptV1` is encoded independently of protobuf:

```text
magic                    13 bytes  "HARCSESSION1\0"
protocol_major           u16 big-endian
protocol_minor           u16 big-endian
library_id               16 raw UUID bytes
host_authority_id        32 bytes
tls_spki_sha256          32 bytes
device_id                32 bytes
grant_id                 16 raw UUID bytes
grant_epoch              u64 big-endian
challenge_id             16 raw UUID bytes
server_nonce             32 bytes
client_nonce             32 bytes
capabilities_sha256      32 bytes
```

`capabilities_sha256` hashes the exact persisted
`NegotiatedCapabilitiesV1` payload bytes containing sorted required/selected
capability IDs, protocol minor, and codec/container choices; peers compare that
payload before signing.

The client signs:

```text
SHA256("HARC-SESSION-CLIENT-PROOF-V1\0" || session_transcript_bytes)
```

`OpenSession` verifies the low-S signature using the registry key and returns a
random token ID plus 32-byte token secret. The host stores only
`SHA256("HARC-SESSION-TOKEN-V1\0" || token_id || token_secret)` with device,
grant epoch, TLS SPKI, issued time, expiry, and the exact
`NegotiatedCapabilitiesV1` bytes/hash, selected protocol minor, codec, and
container. The client sends the base64url
encoding of `token_id || token_secret` only in
`Authorization: HarcSession <credential>` metadata, never a URL or log.

Session lifetime is 30 minutes. There is no refresh token: renewal repeats
`BeginSession` and `OpenSession` with fresh nonces and device proof. Active
streams re-check expiry and registry epoch per message and terminate within five
seconds of expiry, scope change, or revocation. Golden fixtures pin transcript,
capability hash, proof digest, signature, and negative binding cases. V1 does
not depend on mutual TLS.

Bonjour advertises `_harc._tcp` and only nonsecret hints: display name,
protocol major/minor, and capability bitset. Service names, addresses, TXT
records, DNS names, VPN names, and ports are untrusted until the pinned host
handshake succeeds.

The canonical V1 TXT keys are `dn`, `pmaj`, `pmin`, `caps`, and optional
`uport`. Protocol and port values use shortest-form unsigned decimal; `caps`
is exactly 16 lowercase hexadecimal digits. V1 readers reject missing required
keys, unknown keys, noncanonical integers, and invalid display text. The
service is attached through `NWListener.Service` to the exact gRPC listener;
the upload listener is ready before that listener begins advertising, and
generation withdrawal clears the service through a tombstoned owner.

Discovery uses `NWListener` and `NWBrowser`, never custom multicast. The first
permission-triggering mobile browse starts only after a foreground **Connect to
a Host** action and pre-permission explanation. After adoption and granted local
network access, a system-delivered background transfer/completion event MAY run
the bounded recovery browse in Section 13.1 without another tap; it cannot prompt
for permission and safely queues if access or execution time is unavailable.
Local-network denial produces repair instructions; manual address entry does not
bypass the permission or host authentication.

### 13.4 Background HTTPS upload

iOS system-managed background transfer uses:

```text
PUT /v1/uploads/{upload-id}/batches/{batch-id}
Authorization: HarcUpload <opaque-capability>
Content-Type: application/vnd.harc.audio-batch.v1
```

The endpoint is served by `HarcHostTransport` and calls the identical
authorization and ingest application services used by gRPC. The host MUST never
emit a 3xx response for this endpoint, and an integration test enforces that
invariant. Background URLSession may follow a redirect without offering the
ordinary redirect-decision callback, so Harc MUST NOT claim it can prevent that
transmission client-side. An unexpected final URL is a visible security failure;
the client retains its files and accepts no acknowledgement.

The opaque capability is a random UUID token ID plus a 32-byte random secret,
base64url encoded only in the HTTP header. The host stores
`SHA256("HARC-UPLOAD-CAPABILITY-V1\0" || token_id || token_secret)` and binds it
to `LibraryID`, host authority ID, minimum transport-set epoch, device ID, grant
ID and epoch, upload and recording IDs, current upload-session generation and
immutable upload-profile SHA-256,
allowed chunk indexes and hashes, HTTP method,
path, exact immutable batch-body SHA-256, byte ceiling, unique token ID, and
expiry. Default lifetime is seven days and MUST NOT exceed 30 days or the upload
session's expiry, whichever comes first. The longer lifetime accommodates
system-deferred transfer; exact-body binding and live registry checks bound its
authority. Each use re-checks current revocation and epoch state. It also
requires the exact current upload generation and a nonexpired upload session;
reopen or abandon invalidates every prior-generation capability.

After first durable acceptance, the capability becomes `accepted` and only an
exact retry may return the original result. Reuse for different bytes or
metadata is rejected. Expiry before use is recoverable but requires a new
capability through a fresh authenticated session; it never discards the batch.

The successful response body is an exact host-signed `BatchAckV1` containing
protocol version, `LibraryID`, host authority ID, device ID, upload ID, batch ID,
exact batch-body
SHA-256, ordered accepted chunk indexes and hashes, durable time, and ACK ID.
Its `issued_at_unix_ms` is exactly that durable time.
The host persists the exact signed object. The client verifies its pinned host
authority and equality of every local identity/hash field before marking chunks
`durableAtHost`; signature validity alone is insufficient. A lost response is
recovered by reconciliation and returns the identical ACK bytes.

`BatchAckV1` uses envelope message type `transfer.batch-ack.v1`; exact payload,
envelope, object ID, and signature are covered by golden fixtures.

Background mTLS is deferred unless a physical-device spike proves correct
behavior across lock, suspension, process relaunch, client-certificate
selection, and rotation. Pinned TLS plus narrow application capabilities is the
V1 contract.

### 13.5 Limits and quotas

Initial hard limits are part of the tested protocol contract:

| Resource | Limit |
| --- | --- |
| Decoded control protobuf | 1 MiB |
| gRPC message containing one audio chunk | 5 MiB including metadata |
| Ordinary logical chunk duration | 60 seconds |
| Ordinary logical chunk decoded frames | 960,000 mono frames at 16 kHz |
| Encoded logical chunk | 4 MiB |
| Chunk declarations per `DeclareChunks` call | 1,024 |
| Chunk declarations per upload attempt | 4,096 |
| Background batch | 64 MiB hard maximum |
| Edge-processing bundle | 32 MiB total; 1 MiB stream frames; 16 MiB per entry |
| Concurrent upload streams per device | 2 |
| Active upload sessions per device | 4 |
| Default staging quota per device | 20 GiB |
| Default global staging quota | 100 GiB |
| Minimum free host volume | Greater of 10 GiB or 10 percent |

While the gRPC edge contains bootstrap and session-establishment methods only,
its transport decoder enforces the 1 MiB control ceiling before protobuf
decoding. Activating `RecordingTransferService` MUST NOT simply widen that
control edge to 5 MiB: the shared listener must add method-aware predecode
enforcement which retains 1 MiB for control messages and permits the frozen
5 MiB ceiling only for the audio-chunk methods.

The host MUST validate declared lengths before allocation, decode with bounded
streaming buffers, reject unsupported codec parameters, generate all staging
paths, refuse symlinks and path traversal, and rate-limit pairing,
authentication, pagination, search, malformed input, and decoder failures.
Quotas are locally configurable downward or upward, but a quota failure remains
visible and recoverable and never authorizes client cleanup.

Initial token-bucket limits are also tested defaults:

| Operation | Limit |
| --- | --- |
| Public host info/capability requests | 60 per source per minute |
| Pairing claim starts | 5 per source per 10 minutes; one applicant per ticket |
| Session challenges | 10 per device/source per minute; 5 outstanding |
| Durable metadata mutations | 10 per device per minute with burst 20 |
| Search | 30 per device per minute |
| Change pagination and recording reads | 120 per device per minute |
| Decoder/hash failures | 20 per device per hour before a 15-minute cooldown |
| Malformed pre-auth requests | 60 per source per minute before a 10-minute cooldown |

Rate-limit rejection responses MUST NOT reveal whether a device, ticket, or
record exists. Repeated identical low-severity rejection events are aggregated
instead of creating one audit row per packet.

Accepted nonzero replay identities are permanent. Command expiry limits only
first acceptance: an exact replay after expiry still returns the original
durable result, while a different request under the same replay key remains an
audited conflict. V1 therefore retains the exact request fingerprint and
original result rather than deleting an identity after a time horizon. Each
device is capped at 100,000 retained operation rows; at that limit, new
side-effecting commands fail visibly with `resourceExhausted` instead of making
an old `OperationID` reusable.

Expired pairing/challenge/session rows are deleted after seven days. Expired
background-capability records are deleted 30 days after expiry. The library
change log targets 90 days with a hard one-million-row cap. The hard cap wins if
more than one million changes occur inside 90 days: oldest rows are compacted
and any earlier cursor receives `fullResyncRequired`. Tests cover that
cap-overrides-age case. The rolling diagnostic audit keeps at most 100,000
rows or 30 days; exact grants, revocations, manifests, receipts, canonical
recording revisions, and current device state are not discarded with that log.

## 14. iOS capture contract

### 14.1 Audio session and real-time path

Capture starts only after an explicit foreground user action, an accurate
recording disclosure, and microphone permission. While recording, every scene
shows a persistent high-contrast recording indicator, elapsed time, and reachable
Stop control in addition to the system microphone indicator. The target declares
the audio background mode.

The initial audio session profile is `.record` with `.measurement`. It includes
the deployment-appropriate Bluetooth HFP input option (`allowBluetoothHFP` where
available, otherwise the supported predecessor) so AirPods/HFP routes appear.
`.playAndRecord` is used only if a measured product requirement needs simultaneous
playback.

`AVAudioEngine` captures the hardware-native input format. A deterministic
`AVAudioConverter` path produces canonical 16,000 Hz, mono, signed Int16 PCM.
The engine callback only copies samples into a bounded preallocated handoff
buffer. It MUST NOT hash, encode, access files or databases, perform network
work, allocate large objects, or update UI. A serial writer owns conversion,
the master file, and durable frame accounting.

There is one process-wide capture coordinator even when multiple SwiftUI scenes
exist. Network, host, codec, transcript, and model state never gates capture.
On Stop, it first atomically stops accepting new callback buffers, removes the
tap, and stops the engine. The serial writer then drains every buffer accepted
before that boundary, completes conversion, finalizes the master header and
local metadata, synchronizes them, and closes the file. Only after durable
finalization does the coordinator deactivate `AVAudioSession`. Harc MUST NOT
retain the audio background mode merely to keep gRPC, hashing, or encoding alive.

### 14.2 Durable master

The client writes an Application Support master excluded from backup. The active
master uses `completeUnlessOpen` protection and keeps its file descriptor open
while recording. At most five seconds of accepted canonical frames may exist
beyond the last synchronized durable-frame checkpoint. Checkpoint policy may be
tuned only with measured durability and energy evidence.

Capture state is independent of transfer state:

```text
preparing -> recording <-> interrupted -> stopping -> stopped
                                      \-> recoveryRequired
                                      \-> failed
```

An unfinished master is repaired to the last durable frame on launch. Crash,
jetsam, reboot, or user force-quit ends the recording at that point; Harc MUST
NOT claim continuity or automatically reactivate the microphone.

Durable stop/recovery produces host-neutral `FinalizedCapture` metadata with
the producing `DeviceID` and `OriginRecordingID`, capture times/finalization
reason, fixed canonical format, durable total frames/bytes and PCM SHA-256, and
ordered discontinuities. It contains no `LibraryID`, host authority, grant,
upload ID, host path, or host processing artifact. Lossless chunk descriptors
are attached locally as encoding completes. This local record and master are the
source for any later host-bound attempt and explicit user export.

### 14.3 Discontinuities

Interruption begin/end, route change, engine-configuration change, media-service
loss/reset, writer failure, buffer overrun, and recovery produce durable
`CaptureDiscontinuity` values. Each contains the recording ID, monotonic and wall
times, reason, old/new route where known, affected canonical frame range, and
canonicalization policy. V1 records wall-clock gaps as metadata and does not
insert unrecorded silence into canonical PCM. This keeps the client and host PCM
hashes identical while making the missing interval explicit.

Resume occurs only while user recording intent remains and the operating system
permits it. A format-changing route rebuilds the engine, tap, and converter.
Every lost or synthesized interval is visible in mobile status, the signed
manifest, host state, and portable projection.

### 14.4 Data protection, backup, and retention

- The target default is `NSFileProtectionComplete`.
- Active masters override to `completeUnlessOpen` and keep the descriptor open
  only for explicit active recording.
- Immutable masters/chunks/batches, partial batch staging, export staging,
  `HarcTransferStore.sqlite` plus WAL/SHM, task mappings, manifests, and receipts
  use `completeUntilFirstUserAuthentication` so system background completion can
  operate after the device has been unlocked once.
- `HarcLibraryCache.sqlite` plus WAL/SHM and downloaded audio, transcript,
  summary, speaker, waveform, and OKF cache files use `complete` protection.
- The device signing key uses `AfterFirstUnlockThisDeviceOnly` without a
  user-presence constraint.
- Every master, transfer derivative, transfer database, receipt, export-staging
  file, and host-cache directory is marked with
  `NSURLIsExcludedFromBackupKey = true`. V1 intentionally excludes transfer
  state and content from iCloud/Finder device backup; the adopted host is the
  synchronization destination, not OS backup. A restored/reinstalled client
  re-pairs and resynchronizes its cache. Harc discloses that an unuploaded local
  recording cannot be recovered after loss of the physical device.
- Harc verifies protection and backup-exclusion resource values after creation,
  after every atomic rename, for SQLite sidecars after opening/checkpointing,
  and again on relaunch. A directory flag alone is not assumed to repair an
  incorrectly attributed child.
- A protected-data-unavailable launch performs no destructive reconciliation.
- Cleanup is restart-idempotent and begins only after the verified receipt and
  cleanup intent are both durable.

## 15. Audio chunks and compression

### 15.1 Logical chunks

Logical chunks are immutable canonical PCM frame ranges, normally 60 seconds.
They do not depend on audio callback or encoded packet boundaries. Every chunk
contains:

- origin recording and chunk IDs;
- zero-based chunk index, canonical start frame, and frame count;
- sample rate, channel count, and PCM format;
- codec and container identifiers;
- encoded byte length and SHA-256; and
- canonical decoded byte length and SHA-256.

The canonical decoded hash input is mono signed Int16 little-endian PCM bytes.
Chunks are contiguous and non-overlapping. Every compressed chunk has a complete
independent container/header and codec state so it can be decoded in isolation.

The release codec is selected by an early CAF+ALAC versus FLAC physical-device
spike. Both MUST decode bit-exactly. On the oldest supported iPhone, p95 encoding
of a 60-second chunk must finish within ten seconds, encoder queue depth must
remain at most two during a three-hour run, incremental peak memory must remain
below 100 MiB, and encoding must not cause serious or critical thermal state.
Simulator, Catalyst, and iOS-app-on-Mac reports are diagnostic only and MUST
fail qualification. A qualifying report records a physical iPhone hardware
identifier and phone interface idiom in addition to the signed build identity.
Until that decision lands, raw canonical PCM is permitted only for fixtures and
loopback tests; the App Store submission path requires lossless compression.

### 15.2 Host-bound signed recording manifest

`RecordingManifestV1` is not created merely because capture stopped. After a
host tuple is adopted and `BeginUpload` reserves an upload ID, the transfer layer
projects one host-bound manifest from the immutable `FinalizedCapture`, complete
lossless chunk descriptors, and that attempt. With an adopted reachable host,
this may happen immediately after stop; an unpaired/offline recorder does it
later. A different host authority or replacement upload attempt requires a new
manifest signature over the same host-neutral capture facts.

The exact protobuf payload `RecordingManifestV1` contains:

- protocol major/minor, manifest version, required-feature list, and creation
  time;
- `LibraryID`, host authority ID, origin recording ID, upload ID, and producing
  device ID;
- exact `UploadProfileV1` SHA-256 and its selected descriptor/codec/container
  identifiers;
- capture start/end wall and monotonic times plus finalization reason;
- canonical format fixed to 16,000 Hz, mono, signed Int16 little-endian;
- total canonical frame and byte counts;
- SHA-256 of the exact complete canonical PCM byte stream;
- ordered chunk entries containing every field required by Section 15.1;
- ordered `CaptureDiscontinuity` values; and
- optional signed processing-artifact object IDs, never paths.

The chunk list MUST cover exactly `[0, total_frames)` with indexes starting at
zero and no gap, overlap, duplicate ID, integer overflow, or trailing frame.
Concatenating each verified decoded chunk must produce the declared byte count
and complete PCM hash, which also matches the client's durable master prefix.
The payload represents final state and is immutable.

The device signs the exact payload through `HarcSignedEnvelopeV1` with message
type `transfer.recording-manifest.v1`. The manifest identity used by upload,
commit, reconciliation, and receipt is the Section 11 framed signed-object
SHA-256. Host and client persist those exact bytes. A second signed object for
the same upload ID is accepted only when byte-identical; a replacement upload
for the same origin requires Section 16.1 abandonment or expiry plus a new
upload ID. Otherwise it is a conflict/security failure. Golden fixtures pin a multi-chunk
manifest, discontinuities, object ID, and gap/overlap/tamper rejections.

The manifest is durable device provenance, not an authorization command, so its
envelope grant fields are zero as required by Section 11.2. `CommitUpload` is
authorized by the caller's current session, live registry grant/epoch, upload
ownership, and `recording.upload.own` scope. A mid-recording grant epoch change
therefore does not require re-signing the immutable manifest; a revoked or
never-paired device cannot establish the current session needed to submit it.

### 15.3 Background batch container

Background files aggregate logical chunks and are immutable before scheduling.
The initial finalization policy is 8 MiB, ten minutes of audio, or recording
stop, whichever occurs first. The hard maximum remains 64 MiB.

`HarcAudioBatchV1` uses this exact framing:

```text
magic                    8 bytes  "HARCAB1\0"
header_length            u32 big-endian, at most 1 MiB
header_payload           exact AudioBatchHeaderV1 protobuf bytes
for each ordered header entry:
  encoded_length         u32 big-endian, at most 4 MiB
  encoded_chunk          encoded_length bytes
```

The header contains version, batch ID, upload ID, immutable upload-profile
SHA-256, origin recording ID, device ID, and at most 64 ordered entries with chunk ID/index, encoded length/hash,
decoded frame range/hash, codec, and container. Entry count and all lengths are
validated before allocation; trailing bytes are rejected. The capability and
`BatchAckV1` bind SHA-256 of the entire exact batch file.

The client writes a protected `.partial`, synchronizes the file, atomically
renames it, and synchronizes the containing directory before persisting or
scheduling the final URL. Only that immutable final URL is given to background
URLSession. A batch fixture pins framing, body hash, parser bounds, and
truncation/trailing-byte failures.

## 16. Upload sessions and client transfer state

### 16.1 Incremental declaration and final manifest

The upload protocol deliberately separates capture-time declarations from the
one final signed manifest, so a Mac may upload while it is still recording:

1. `BeginUpload` carries the client-generated upload ID, origin recording ID,
   active `(LibraryID, HostAuthorityID)`, producing device ID, canonical PCM
   format, optional capture-start metadata, and an exact `UploadProfileV1`.
   That profile freezes selected protocol minor, descriptor schema/capabilities,
   lossless codec/container and parameters, canonical format, and the SHA-256 of
   the session's exact `NegotiatedCapabilitiesV1`. It reserves that identity but
   declares no final frame count or manifest.
2. After each logical chunk is finalized, `DeclareChunks` appends one or more
   immutable typed `ChunkDescriptorV1` values in contiguous index/frame order.
   Each descriptor contains every Section 15.1 field. An exact repeat is an
   idempotent success. Reusing a chunk index or ID with any different field is a
   typed conflict, blocks further data for that upload, and requires explicit
   abandon/restart; the host never silently replaces a declaration. The host
   persists the validated typed value. Unknown descriptor fields are rejected
   in V1 unless a negotiated required capability defines and includes them in
   equality. V1 therefore rejects unknown fields anywhere inside a chunk
   descriptor instead of normalizing them away. One call carries at most 1,024
   descriptors and one upload attempt carries at most 4,096, keeping durable
   ledgers and reconciliation responses within the control-plane ceiling.
   Protobuf wire spelling is not an identity and is never compared; generated
   gRPC decoding may normalize known fields.
3. `UploadChunks` sends bytes only for previously declared descriptors. Active
   gRPC and the background batch path use the same declaration records and
   staging service. `MintBackgroundCapability` covers only an exact set of
   declared, not-yet-committed descriptors and an exact immutable batch body.
4. After durable capture finalization, complete chunk encoding, and an adopted
   upload reservation, the client creates and signs the single host-bound
   `RecordingManifestV1`. `CommitUpload` submits that exact framed
   signed object. It closes declaration, requires the manifest's descriptor
   list to equal the full declaration set in order by exhaustive typed-field
   equality, including every field enabled by negotiated capabilities, and then
   commits only after every declared chunk is durable. An exact repeat returns
   the original result. A different manifest object for the same upload ID is a
   conflict and never mutates the bound object.

`BeginUpload` is idempotent for an exact owner/origin/upload tuple. At most one
nonterminal upload ID may exist for an origin recording. A new upload ID for the
same origin is accepted only after the prior attempt is explicitly abandoned or
has expired, and the producing device must still retain its master. If the
origin is already committed, `BeginUpload` returns `alreadyCommitted` and the
exact existing receipt rather than creating a second canonical recording.

The host persists the exact upload profile/hash for the attempt. Every upload
RPC/message made under an active session, plus every chunk, manifest, and
background capability, must name that hash. A later session may contain extra
unrelated negotiated features, but its protocol,
descriptor, codec/container, canonical-format, and required transfer semantics
must equal the frozen upload profile. Reopen preserves it. If either peer can no
longer support that profile, the client retains the host-neutral master and must
explicitly abandon/start a new attempt; it never silently reinterprets staged
bytes.

An upload session has a fixed 30-day absolute expiry from its first
`BeginUpload`; activity does not slide that deadline. Grant expiry may shorten
it. At expiry, data acceptance and every capability for that generation stop.
The same device MAY reopen the same uncommitted upload ID through a fresh
authenticated `BeginUpload`: the host increments a private generation counter,
sets a new 30-day deadline, invalidates all prior-generation capabilities, and
preserves immutable declarations and a bound final manifest if present. Missing
staged bytes are uploaded again. This makes a retained master recoverable
without changing a signed manifest.

`AbandonUpload` is an authenticated, idempotent terminal transition available
only to the owning device. It invalidates capabilities and permits a fresh
upload ID and newly signed manifest for the same origin; it never deletes the
client master or a committed recording. Host staging for an expired or
abandoned attempt is eligible for deletion after seven days. The minimal
attempt identity and every supersession edge are permanent: once a newer upload
ID has been accepted for an origin, an older ID can never become eligible again
because the newer attempt later expires or is abandoned. Descriptor hashes,
bound-manifest identity, generation history, and terminal reason remain durable
for deterministic replay and provenance; a future compaction may remove bulky
detail only if it preserves those identities and decisions. Reaping immediately
frees the attempt from the four-active-session quota. Quota exhaustion first
reaps eligible staging bytes and otherwise returns a visible recoverable error.

### 16.2 Client outbox

The recording-level outbox state is:

```text
localOnly -> queued -> authorizing -> activeUpload -> hostCommitPending
                              \-> backgroundScheduled -/
hostCommitPending -> committed
any nonterminal -> failedRecoverable
any authorized state -> securityBlocked
```

`committed` requires a persistently stored, verified `RecordingReceipt`.
`securityBlocked` requires user action and MUST NOT retry forever. Processing is
a separate status and never changes audio retention eligibility.

Each logical chunk is `pending`, `encoding`, `ready`, `scheduled`, `sending`,
`durableAtHost`, or `failedRecoverable`. State transitions and file creation are
transactionally coordinated or restart-reconciled. The exact encoded chunk and
immutable batch bytes MUST remain locally available through a verified recording
receipt, even after a staging ACK. The canonical master alone is not sufficient
because a later re-encode is not assumed to be byte-deterministic and would not
match the declared encoded hash.

`ReconcileUpload` returns session generation/expiry, immutable declarations,
the bound manifest identity if any, durable indexes and hashes, rejected indexes
with typed reasons, terminal reason, and an existing receipt when commit already
succeeded. Client retries operate at missing logical-chunk or immutable-batch
boundaries.

One stable background URLSession identifier,
`com.harc.mobile.recording-upload`, is used with
`URLSessionConfiguration.background(withIdentifier:)` and
`sessionSendsLaunchEvents = true`. Uploads use a delegate-based session and
`uploadTask(with:fromFile:)` against immutable protected files. Task-to-batch
mapping is persisted before `resume()`.
The transfer-store transaction also persists the raw capability credential,
all server bindings/expiry, immutable body URL/hash, and task mapping before
`resume()`; `URLSession.originalRequest` is never its sole credential source.
The secret is never logged or copied to the library cache. It is deleted only
after verified receipt cleanup, terminal abandon, or expiry after every bound
system task is cancelled/reconciled; batch bytes remain when an expired secret
is removed.

The SwiftUI app installs a UIKit app-delegate adapter implementing
`application(_:handleEventsForBackgroundURLSession:completionHandler:)`. On
every launch it recreates the same session, calls `getAllTasks()`, reconciles
operating-system tasks against its outbox, and only then schedules replacements.
For terminal reachability failures it follows Section 13.1's authenticated
rediscovery/rescheduling rule with the same immutable body and capability.
The stored system completion handler is called from the handling triggered by
`urlSessionDidFinishEvents(forBackgroundURLSession:)`, after all resulting
outbox transactions finish. System termination may relaunch the app for
completion events. User force-quit preserves all state and retry begins after
the next manual launch.

Active gRPC is not an iOS background-execution mechanism, and V1 does not depend
on `BGTaskScheduler` to make an upload file ready. Chunk encoding and batch
finalization run incrementally while capture or ordinary foreground execution is
legitimate; only complete immutable files enter background URLSession.

## 17. Host ingest and receipt contract

### 17.1 Host journal

An upload moves through restart-idempotent host states:

```text
receiving -> manifestVerified -> assembling -> audioPublished
          -> recordingCommitted -> receipted -> processing -> complete
any pre-receipt state -> failedRecoverable
```

A chunk acknowledgement means its exact bytes and metadata are verified,
flushed to the staging area, and recorded durably in `HarcHost.db`. It does not
mean a canonical recording exists.

Commit order is fixed:

1. authorize the current device, grant epoch, upload, quotas, and ownership;
2. verify complete manifest coverage with no gaps or overlaps;
3. decode with bounds and verify every encoded and canonical PCM hash;
4. assemble the canonical WAV in a host-generated `O_CREAT|O_EXCL`, no-follow
   sibling temp inside the final canonical directory on the same volume; never
   accept a client name or cross-volume `EXDEV` fallback;
5. synchronize the temporary file;
6. atomically publish the WAV with same-directory rename at the host-owned
   canonical path;
7. synchronize the destination directory so the rename is durable;
8. idempotently insert or recover a `pendingProcessing` row and change-log entry
   in `Harc.db` using the origin identity and PCM hash;
9. persist publication linkage in `HarcHost.db`;
10. create, sign, persist, and synchronize the exact receipt bytes; and
11. return the receipt, then schedule processing asynchronously.

Every boundary, including post-rename/pre-directory-sync and
post-directory-sync/pre-database, has a kill/restart and power-loss integration
test. Replay after any crash must
continue, return the same result, or expose a recoverable failure. It must never
publish duplicate canonical rows or files.

### 17.2 Recording receipt

The signed receipt payload contains:

- protocol version, `LibraryID`, and host authority ID;
- origin and canonical recording IDs;
- upload ID and signed manifest object SHA-256 from Section 11;
- canonical PCM SHA-256, frame count, sample rate, channel count, and exact PCM
  format (`signedInt16LittleEndian` in V1);
- canonical recording revision and change cursor;
- `issued_at_unix_ms`, exactly equal to durable commit time, and processing
  state; and
- receipt ID.

The receipt is host-signed through `HarcSignedEnvelopeV1` with message type
`transfer.recording-receipt.v1`. It proves that the
canonical audio and `pendingProcessing` database row are durable. It does not
promise STT, diarization, summary, JSON, or OKF completion. A dropped response
after commit is recovered by origin ID or upload ID and returns the identical
receipt bytes.

### 17.3 Client deletion gate

`VerifiedRecordingReceipt` is created only by a validator with the local outbox
record, exact signed manifest object, and paired host authority in hand. It MUST:

1. parse the exact framed object without reserialization;
2. require message type `transfer.recording-receipt.v1` and payload type
   `harc.v1.RecordingReceiptV1`;
3. verify a canonical low-S signature with the pinned host authority key;
4. match envelope and payload `LibraryID` and host authority ID to the adopted
   host;
5. match origin device/recording ID and upload ID to the local outbox;
6. match the exact signed-manifest object SHA-256;
7. match canonical PCM SHA-256, total frames, sample rate, channels, and PCM
   format to the local final manifest/master;
8. require a nonzero canonical recording ID, revision, change cursor, receipt
   ID, and durable commit time; and
9. reject unknown critical fields, conflicting prior receipts, or any mismatch
   into `securityBlocked` while retaining every local file.

Signature validity alone never produces this type. In one client-store
transaction, Harc persists the exact receipt, records validation evidence,
changes the recording to `committed`, and marks cleanup eligible. Only that
transaction's durable `VerifiedRecordingReceipt` may enter retention cleanup.
Golden and negative fixtures cover every equality check and a valid signature
over the wrong recording, host, manifest, or audio hash.

## 18. Canonical library, projections, and recovery

`Harc.db` is authoritative coordinated library state. Canonical WAV and the
user-owned structured JSON and OKF Markdown are portable artifacts/projections.
OKF is not a transport envelope and does not replace typed protobuf commands.

After receipt, the ordinary processing scheduler uses the existing `harc-stt`
daemon. Processing state progresses independently:

```text
pending -> transcribing -> projecting -> ready
                         \-> degraded
                         \-> failedRecoverable
```

Store-mediated results and metadata mutations regenerate JSON and OKF using
host paths. A client path never appears as the canonical `resource`. Pending or
failed processing remains a visible recording with playable committed audio and
explicit state.

Incomplete remote uploads are not inserted into the existing local-WAV
`RecoveryQueue`. `HarcHost` exposes a separate upload-recovery source, and the UI
may aggregate both sources behind a shared recovery presentation.

Exact signed manifests and receipts MUST also be preserved beside the
portable recording artifacts so the host SQLite indexes can be reconstructed
without losing provenance.

## 19. Library synchronization and conflicts

An initial or compacted client calls `BeginLibrarySnapshot`. In one `Harc.db`
read transaction, the host records the current change cursor as
`snapshot_anchor` and materializes exact authorized, path-free recording views
and tombstones in stable canonical-ID order. Snapshot views contain metadata,
revisions, and processing/projection descriptors, not audio or transcript bodies;
permitted detail is fetched explicitly. Materialization counts against host
staging quotas. The opaque snapshot token is bound to device, grant epoch,
scopes, and anchor; it expires after 30 minutes, and each device may hold one
snapshot. Pages are at most 1 MiB decoded.

`ListSnapshotPage` returns materialized bytes plus an opaque next-page token, so
concurrent mutations cannot change later pages. The client stages all pages,
then in one `HarcClientStore` transaction replaces only canonical cache rows and
sets its cursor to `snapshot_anchor`; upload/mutation outboxes, receipts, and
uncommitted masters are preserved. It immediately calls `ListChanges` after the
anchor to receive changes made during snapshot creation or paging. An expired
snapshot restarts without applying a partial cache.

`ListChanges(after:limit:)` returns ordered upserts and tombstones plus the next
cursor. Applying a delta page and advancing the local cursor is one transaction.
The server returns `fullResyncRequired` when requested history was compacted.
Tests mutate, add, and delete records during every snapshot page boundary and
prove convergence without losing client outbox state.

Network recording views expose stable public IDs, revision, metadata,
transcript, speaker labels, discontinuities, processing state, permitted audio
descriptors, and projection version. They never expose GRDB models or paths.

An exact `MetadataMutationV1` payload contains protocol version, `LibraryID`,
host authority ID, requesting device ID, current grant ID/epoch, operation ID,
issued time, command expiry, canonical recording ID, expected revision, and one
registered typed field mutation. It uses the Section 11
`library.metadata-mutation.v1` row. Offline mutations are signed durable
operations with `expected_revision`.
Success returns the new revision and change cursor. Conflict returns the current
server value and revision; the client surfaces keep-mine, use-host, or an
operation-specific merge when one is defined. Last-write-wins is not the silent
default. Revoked mutations remain visible but cannot be resubmitted without a
new user decision after re-pairing.

## 20. Desktop client and edge-processing policy

Mac Client mode retains current microphone and ScreenCaptureKit capture and the
local `harc-stt` daemon. Capture and upload run concurrently, so local transcript
latency and model-cache reuse do not depend on the host.

A signed `ProcessingArtifactV1` is provenance metadata, not a self-containing
result. It includes protocol version, `LibraryID`, host authority ID, artifact
ID, origin recording ID and canonical audio hash, producing device, current
grant ID/epoch, unique operation ID, creation time, submission expiry,
engine/build and exact model revisions, diarization/VAD/vocabulary/prompt
versions, word-timing schema, covered/degraded/failed frame ranges, exact bundle
byte length, and `bundle_sha256`. The envelope's ordinary `payload_sha256`
hashes these exact metadata bytes; `bundle_sha256` separately hashes the entire
content container below, so no field is self-referential.

`HarcProcessingBundleV1` is framed as:

```text
magic                    8 bytes  "HARCPB1\0"
header_length            u32 big-endian, at most 1 MiB
header_payload           exact ProcessingBundleHeaderV1 protobuf bytes
for each ordered header entry:
  payload_length         u64 big-endian, at most 16 MiB
  payload                exact entry protobuf bytes
```

The header contains protocol version, artifact ID, origin recording ID,
canonical audio hash, and at most eight ordered entries. Each descriptor has one
registered type/schema version, byte length, and SHA-256. V1 entry payloads are:

- `TranscriptArtifactV1`: locale plus ordered utterances and words with UTF-8
  text, canonical start/end frames, optional confidence, and local speaker ID;
- `DiarizationArtifactV1`: ordered nonoverlapping speaker turns and local cluster
  IDs, without voice embeddings;
- optional `SummaryArtifactV1`: summary/action-item Markdown with exact prompt
  and model provenance; and
- `CoverageArtifactV1`: complete covered, degraded, and failed frame ranges with
  registered reason codes.

Lengths/hashes are checked before protobuf parsing, unknown entry/schema types
are rejected unless negotiated, all frame ranges are bounded by the recording,
trailing bytes are rejected, and total decoded text is bounded. The whole bundle
is at most 32 MiB. `SubmitOwnArtifact` sends the exact signed metadata object
first and then the exact bundle in ordered frames of at most 1 MiB; host staging
is operation-ID idempotent and publishes nothing until the complete bundle hash
and typed invariants pass.

The metadata uses the Section 11 `processing.artifact.v1` row. The host may
accept it without repeating work only when the current grant authorizes
submission and the audio hash, complete coverage, bundle, and locally configured
pipeline compatibility all match. Otherwise it schedules its own processing
without delaying the audio receipt.

The signature establishes origin and integrity, not trustworthy execution. V1
does not send other devices' audio to a client for shared work. Library audio
download and retention are separately configurable, especially on managed work
computers.

## 21. Host migration and loss

V1 has no transparent authority migration. Moving a library means:

1. stop or disable Host mode on the old host;
2. while the old authority is still available, create the portable trust-history
   bundle below, then copy canonical `Harc.db` including its unchanged
   `LibraryID`, canonical audio, JSON/OKF projections, and exact signed
   manifest/receipt provenance through an explicit local migration workflow;
3. create a new authority, transport set, and fresh `HarcHost.db` on the
   destination, with migrated writer mode reset to standalone;
4. verify the migrated library and select one active writer; and
5. re-pair every client.

Pairing tickets, claim/session tokens, background capabilities, active grants,
grant epochs, revocation authority state, upload leases, and processed-operation
authorization state from the old `HarcHost.db` MUST NOT become active on the new
authority. Old signed provenance is retained as history; it does not authorize
the new host. A pending client upload abandons the old-authority attempt locally,
retains its host-neutral `FinalizedCapture` and exact encoded chunks, then after
re-pairing creates a new upload ID and new-authority manifest. It receives a
receipt signed by the new authority without changing its origin or canonical PCM
identity.

Pending clients keep masters and may upload them after adoption by the new host.
The old authority private key MUST NOT be silently copied to two hosts. Authority
key loss requires re-pairing unless a future reviewed encrypted recovery design
exists. Future transparent migration requires signed authority transitions,
monotonic epochs, rollback detection, old-host retirement, and split-brain
resolution and is outside this specification.

Host startup validates the exact `(LibraryID, HostAuthorityID, HostStateID)`
tuple, transport epoch high-water mark, and security-registry revision across
canonical library metadata, `HarcHost.db`, and the authority-key record before
acquiring the writer lease. A missing, reset, rolled-back, or
inconsistent Host database is a fail-closed recovery state: no listener starts,
no transport set is reissued at a reset epoch, MCP receives no direct fallback,
and the old authority is not reused with an empty registry.

Recovery is either an exact verified restore of the mutually consistent library,
Host database, matching key reference, nondecreasing Keychain epoch mark, and an
equal registry revision (or its one exact journaled N+1 completion), or a
foreground OS-authenticated
**Create replacement host authority** operation. The latter archives any
verifiable public history, disables the old tuple, creates a new authority and
HostStateID with epoch one, returns writer mode to standalone until explicitly
re-enabled, and requires every client to re-pair through the authority-replacement
transaction below. It never tries to infer or reset an old epoch high-water mark.

Before export, the old host creates an exact `PortableTrustHistoryV1` payload
containing protocol version, `LibraryID`, old authority ID and X9.63 public key,
export ID/time, the relevant devices' X9.63 public keys, and the exact signed
grant/revocation objects needed to validate every migrated manifest. It signs
that payload through the Section 11 `migration.trust-history.v1` row. The bundle,
old signed manifests, and old signed receipts are copied as portable sidecars and
verified before the destination claims migration success.

The destination stores this material in a read-only historical trust namespace.
It may use it to verify provenance and rebuild indexes, but it MUST NOT load an
old device, grant, ticket, capability, transport set, or authority key into its
current registry or session validator. Private keys are never included. A
missing or invalid history bundle leaves affected provenance visibly
`unverifiableHistorical`; it is never silently treated as valid.

When pairing sees the same `LibraryID` under a different `HostAuthorityID`, it
MUST present an authority-replacement warning and require an explicit local user
choice plus OS authentication. One client-store transaction archives the old
active tuple and its epoch high-water mark as history, installs the exact new QR
authority/transport set as the sole active tuple, and initializes the new tuple's
high-water mark from that set. It never deletes or resets the old tuple and never
compares epochs across the two authorities. Ordinary pairing cannot silently
replace an authority for a remembered library.

## 22. Local administration and privacy

Pairing start/approval, scope elevation, revocation, migration, and any future
key recovery are local host operations. Pairing approval requires an interactive
foreground confirmation; scope elevation and migration additionally require OS
user authentication. Initial pairing also requires OS authentication when the
grant exceeds Section 12's minimal scope set. Pairing mode closes when its
approval UI disappears.

V1's mandatory Host-mode MCP adapter uses a bounded, length-framed `AF_UNIX`
`SOCK_STREAM` at `~/Library/Application Support/Harc/IPC/host.sock`. The resident
Harc process creates the parent as `0700`, rejects symlink/non-socket stale
entries with `lstat`, binds under umask `077`, and enforces socket mode `0600`.
File ownership is defense in depth; kernel peer identity is authoritative.

For crash recovery, an existing current-user socket is probed with `connect`.
A live peer means another resident host owns the path and startup fails as a
duplicate. `ECONNREFUSED` permits cleanup only after a second no-follow stat
matches the original device, inode, owner, mode, and socket type; Harc then
unlinks through the already opened parent directory and binds. Any changed path
or other error fails closed. Integration tests cover crash/restart, live
duplicate, symlink, non-socket, wrong-owner, and swap-race cases.

Immediately after connect and before reading or writing an application frame,
both peers call `getpeereid` and
`getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` on that connected descriptor. They
derive EUID from the returned `audit_token_t`, require the current user's EUID,
and pass the exact token as `kSecGuestAttributeAudit` to
`SecCodeCopyGuestWithAttributes`. They validate the resulting live `SecCode`
against the designated requirement below, including dynamic validity. A
request-provided PID or PID-only lookup is forbidden because it permits reuse
races. Any credential, audit-token, or code-validation failure closes the socket
without parsing a request.

Release builds pin these exact designated identities under the nonempty Team
Identifier read from the running Harc signature:

```text
host: identifier "com.harc.Harc" and anchor apple generic
      and certificate leaf[subject.OU] = <Harc TeamIdentifier>
mcp:  identifier "com.harc.Harc.mcp" and anchor apple generic
      and certificate leaf[subject.OU] = <Harc TeamIdentifier>
```

PR 6 gives the embedded executable the signing identifier
`com.harc.Harc.mcp` and verifies the final nested code signature. Harc requires
the MCP identity on accepted sockets; `harc-mcp` reciprocally requires the host
identity before sending content. After mutual OS/code validation, MCP sends only
`HARC-MCP-IPC-V1`, a protocol version, and a random 32-byte nonce. The host
echoes that nonce with its own nonce and selected version on the same connection.
Only after the exact nonsecret hello succeeds may either side send tool names,
arguments, library data, or results.

Unsigned/ad-hoc debug tests use an injected `MCPPeerAuthorizing` fake only in
the test process. No environment variable, preference, launch argument, or
Release code path disables the production requirement; a locally built product
without the required signatures cannot enable Host-mode MCP and reports that
configuration explicitly.

The framed IPC interface is an exact allowlist matching today's MCP tools:
`search_notes`, `get_recording`, `list_recent`, `update_summary`, `update_title`,
`update_tags`, `append_note`, and `set_speaker_name`. Adding or broadening a tool
requires a spec/security review. The existing `get_recording.wav_path` argument
may remain a same-machine compatibility lookup only; the host resolves it to an
existing canonical row and returns no arbitrary file contents.

The interface MUST NOT expose pairing start/approval, grant or scope changes,
revocation, migration, authority/TLS key rotation, writer-mode changes,
capability minting, raw SQL/arbitrary file access, or any other local
control-plane operation. Every mutation still calls the canonical host
store/projection/change-log path.

The Mac UI itself calls host services in process. Any future UI-to-agent
privileged IPC must enforce an independently specified allowlist plus the same
user and signing checks.

Security events are host-sequenced and include pairing, grant changes,
revocation, authentication failure, quota rejection, upload commit, receipt
recovery, and migration. Logs MUST NOT contain pairing secrets, capabilities,
private keys, authorization headers, audio, transcript text, or user content.
They are diagnostic and at most tamper-evident, not immutable against a
compromised host.

No third-party analytics or crash uploader may be added as part of this work.
Local diagnostics default to content-free metadata and require explicit export.

## 23. Initial schema map

The protocol source tree is:

```text
Protos/
├── harc_common.proto       IDs, versions, errors, revisions, capabilities
├── harc_identity.proto     host info, transport sets, grants, sessions
├── harc_pairing.proto      ticket claim and pairing status
├── harc_transfer.proto     manifests, chunks, batches, ACKs, receipts
├── harc_library.proto      views, changes, tombstones, mutations
├── harc_processing.proto   provenance artifacts and processing status
└── harc_migration.proto    portable public trust-history provenance
```

The schema MUST distinguish these facts:

- `ChunkAck`: one chunk is durable in host staging;
- `RecordingReceipt`: canonical audio and a pending record are durable;
- `ProcessingStatus`: asynchronous derived work state; and
- `ProjectionStatus`: structured JSON and OKF materialization state.

Domain types own invariants. Proto conversion validates lengths, enum support,
field combinations, frame arithmetic, and identity consistency before a value
reaches `HarcHost` or client persistence.

## 24. Apple target declarations

### 24.1 iOS

Required Info.plist values:

- `NSMicrophoneUsageDescription`;
- `NSCameraUsageDescription` for QR scanning;
- `NSLocalNetworkUsageDescription`;
- `NSBonjourServices` containing `_harc._tcp`; and
- `UIBackgroundModes` containing only `audio` for V1.

The required entitlement is
`com.apple.developer.default-data-protection = NSFileProtectionComplete`.
Network Extension, Personal VPN, multicast, background fetch, background
processing, push, Keychain Sharing, App Groups, and Bluetooth background modes
MUST NOT be added without a separate demonstrated requirement.

The target also needs accurate privacy strings, a `PrivacyInfo.xcprivacy`, no
broad `NSAllowsArbitraryLoads`, and an export-compliance determination covering
TLS and application signing. App Privacy answers are reviewed against the final
implemented behavior rather than assumed from the user-owned-host design. The
app UI and App Store metadata expose the same current privacy-policy URL before
App Store submission.

### 24.2 macOS host and client

When PR 6 enables Bonjour in the Mac app, `HarcApp/Info.plist` MUST add an
accurate `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing
`_harc._tcp`. A Mac that only advertises Host mode and a Mac that browses in
Client mode are both covered by the declaration. No multicast or Network
Extension entitlement is added for Bonjour.

## 25. Verification strategy

### 25.1 Automated layers

Every implementation PR adds focused tests at its lowest stable boundary:

- domain invariants and signed-envelope golden vectors;
- fresh and upgrade database migrations with data-preservation and idempotent
  rerun cases;
- in-process host application-service tests without sockets;
- gRPC/HTTPS loopback tests using the same ingest service;
- QR/ticket, SAS, transport-set, certificate-extension, and protocol-compatibility
  golden vectors;
- session restart and upload-profile/capability binding tests;
- duplicate, reordered, truncated, corrupt, over-limit, revoked, and replayed
  requests;
- kill-point ingest and receipt recovery tests;
- capture/master repair, protected-file, backup-exclusion-after-rename, and
  relaunch tests;
- Unix-socket path ownership, same-UID/audit-token/code-signing, stale-socket,
  peer-crash, and resident-host-loss tests; and
- delta-sync, tombstone, compaction, CAS-conflict, and revocation tests.

The repository-level gate for every PR remains:

```bash
xcodegen generate
swift test
xcodebuild \
  -project Harc.xcodeproj \
  -scheme Harc \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

After the mobile target lands:

```bash
xcodebuild \
  -project Harc.xcodeproj \
  -scheme HarcMobile \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Simulator compilation is necessary but never sufficient for capture or
background-transfer acceptance.

### 25.2 Physical-device matrix

Test at least the oldest supported iPhone/OS, a current non-Pro iPhone/current
iOS, and one current iPad before iPad support ships. Cover built-in and
AirPods/Bluetooth input, Wi-Fi, and cellular hardware.

| ID | Scenario | Required result |
| --- | --- | --- |
| C1 | 60 minutes, ten lock cycles, host absent | Exact durable PCM except explicit discontinuities; remains local |
| C2 | Three hours locked, oldest device, Low Power Mode | Bounded queue/memory; no corruption or critical thermal state |
| C3 | Phone/Siri interruption while locked | Durable discontinuity and correct resume or visible stop |
| C4 | AirPods disconnect and format-changing route | Converter rebuilt; no silent timeline corruption |
| C5 | Randomized force-quit during recording | Playable repair through last durable frame; no auto-resume claim |
| C6 | Reboot before and after first unlock | No protected-data deletion; repair only after unlock |
| C7 | Storage exhaustion through a test quota hook | Visible failure and durable prefix; never zero-byte success |
| T1 | Active gRPC, host power loss/restart | Capture unaffected; resume at missing chunk boundary |
| T2 | Background HTTPS, suspension and system termination | System relaunch path records durable ACK |
| T2b | Background task delayed more than two hours; host restarts and DHCP address changes | Persisted port plus `.local` resolution lets the existing scoped capability succeed without foreground renewal |
| T2c | Deferred batch crosses a normally ordered TLS leaf cutover | Client persisted N+1 before scheduling; overlap floor is honored and the exact batch succeeds on an authorized leaf |
| T2d | Forced host-name/upload-port change | Completion-event rediscovery either reschedules the exact body/capability safely or leaves it queued for the next system/foreground opportunity; no duplicate or trust bypass |
| T2e | Adopted client is offline for N+1 prepublication and returns after new-leaf cutover | Trust callback verifies the new leaf's authority-signed extension, advances the tuple high-water mark, and connects without accepting an unsigned hint |
| T3 | User force-quit during background upload | Outbox survives; reschedules after manual launch |
| T4 | Wi-Fi to cellular to Wi-Fi | Policy respected; idempotent resume; no duplicate |
| T5 | Commit followed by lost response | Reconcile returns identical signed receipt |
| T6 | Duplicate/reordered/truncated/corrupt input | Safe reject/retry; never altered commit |
| T7 | TLS pin mismatch, revocation, expired capability | Actionable security stop; no insecure fallback |
| P1 | Microphone/camera/local-network denial combinations | Local recording remains available where possible |
| H1 | Windows closed, app quit, host asleep/restarted | Accurate reachable/offline state and safe queuing |

C1, C2, T1, and T2 must pass three consecutive times on the oldest and current
iPhones. Every committed WAV must match the mobile canonical PCM SHA-256. No
scenario may create a duplicate canonical recording, delete the final copy
before receipt, or omit a lost interval silently.

## 26. Ordered implementation pull requests

### PR 0 — Ratify constraints and baseline

Land this spec, architecture, plan, module READMEs, `AGENTS.md`, `SECURITY.md`,
and the dated baseline. Fix the deterministic marketing-version fallback test
drift and obtain a green full baseline before feature code.

### PR 1 — Stable identity, revisions, and change log

Add `HarcDomain`, migrate `Harc.db`, retain legacy path-based standalone ingest,
and test public UUID, origin idempotency, canonical hash, revision, processing
state, change cursor, and tombstones. A populated legacy database receives one
stable `LibraryID`, UUID/revision backfill for every row, and succeeds through an
initial anchored client snapshot in upgrade tests.

### PR 2 — Capture/publication seam

Make `RecordingSession.stop()` yield a `CapturedRecording`. Introduce
`RecordingCommitter`; the standalone implementation reproduces today's file,
projection, store, and UI side effects exactly. Client outbox publication comes
later.

### PR 3 — Identity, transfer, client store, and host core without sockets

Activate `HarcIdentity`, `HarcTransfer`, `HarcClientStore`, and transport-free
`HarcHost`; add `HarcHost.db`, migrations, key abstractions, state machines,
authorization, staging, idempotency, and loopback application-service tests.
Add a non-shipping signed iOS 18 `HarcMobileSpikes` harness, run the CAF+ALAC
versus FLAC matrix, and freeze the lossless codec/container before PR 5.

### PR 4 — Protobuf and signing wire contracts

Activate `HarcProtocolWire` and `HarcProtocol`, all seven schema files, code
generation, services, domain conversions, binary ticket/transport encodings,
the signed-envelope registry/golden vectors, and protocol compatibility
fixtures. No network listener lands yet.

### PR 5 — Local ingest and signed durable receipt

Implement canonical WAV publication, pending record commit, exact
`RecordingReceiptV1`, crash journal, recovery, and asynchronous handoff to the
existing daemon using the PR 4 wire/envelope contract. Do not add networking or
extract FluidAudio yet. The decoder interface is bounded and injectable;
production includes the codec selected in PR 3, while raw PCM is fixture-only.

### PR 6 — Host/client transports, discovery, and CLI pairing

Activate the dedicated gRPC HTTP/2 and narrow HTTPS HTTP/1.1 adapters, pinned
TLS, application sessions,
background capability issuance, Bonjour, embedded host lifecycle, revocation,
and a CLI test client. Route bundled `harc-mcp` through authenticated same-UID
local IPC in Host mode with no direct-store fallback. Use the non-shipping
`HarcMobileSpikes` target for physical background TLS, delayed upload across
restart/DHCP change, forced route change, correctly ordered leaf cutover, and
gRPC TransportServices feasibility before freezing the production iOS adapter.

### PR 7 — iOS shell, durable capture, and outbox

Add the HarcMobile Xcode target, onboarding, QR flow, audio capture, file
protection, persistent recording indication, discontinuities, the selected
lossless codec, outbox, active gRPC, background
URLSession adapter, reconciliation, and recording status. Preserve standalone
record/playback/export without a host. The first target is iPhone-only
(`TARGETED_DEVICE_FAMILY = 1`); iPad ships only after its separate device/UI gate.

### PR 8 — Mobile cache and delta-sync library

Add recent recordings, search, detail, playback, processing/projection status,
offline cache, changes/tombstones, scoped mutations, conflict UI, and cache
controls.

### PR 9 — Desktop Client mode and edge artifacts

Add Standalone/Host/Client modes, Mac pairing, client outbox, local daemon
processing, signed provenance, host acceptance policy, cache controls, and
managed-work-device restrictions. Preserve a pre-existing local library as a
separate **On This Mac** source; never merge or upload it implicitly.

### PR 10 — Optional inference extraction and host agent

Only after the vertical slice is stable, consider `HarcInference`, supported
on-device inference, shared writer primitives, and a sole-writer host agent.
Each is separately justified and may remain deferred.

Every PR has its own migrations, unit/integration tests, Mac regression gate,
and rollback-safe behavior. No PR is a repository-wide reorganization.

## 27. Release slices and completion gates

### Local-network physical alpha

PRs 0 through 7 are complete when a new iPhone pairs locally, records through
lock, survives host/network loss, transfers compressed audio, persists a signed
receipt, and observes host processing status. C1, C2, T1, and T2 are green on
physical devices.

This is a physical-development milestone, not an App Review claim.

### Useful mobile beta

PR 8 is complete when recent library data, transcript detail, playback, offline
cache, delta sync, and conflict-aware metadata updates work without database or
path leakage.

### Edge-capable system

PR 9 is complete when a secondary Mac pairs, records and transcribes locally,
uploads concurrently, and the host accepts or visibly reprocesses provenance-
bearing artifacts.

### Release hardening

The full reliability/security matrix, accessibility, upgrade recovery,
privacy/export disclosures, App Review path, and documentation are green.
Review notes include a demo path because reviewers cannot access the developer's
host LAN.

The first App Store submission occurs only after recording consent and the
persistent indicator are verified, a reviewer-accessible demo/sample flow and
privacy-policy metadata exist, App Privacy/export answers match the exact build,
and App Review notes explain background audio and offline use. TestFlight is
optional and does not satisfy or replace any release gate.

## 28. Initial engineering estimate

For one experienced Apple-platform engineer, PRs 0 through 7 are an estimated
8–12 focused engineering weeks after the critical transport/codec spikes succeed.
A polished mobile library, desktop Client mode, remote private-network testing,
upgrade/recovery hardening, and adaptive iPad work make the full program more
realistically 20–28 weeks. These are planning ranges, not delivery promises;
each vertical slice replaces assumptions with measured throughput.

## 29. Required early spikes

The following questions are intentionally resolved with code and physical
evidence, not parallel speculative implementations:

1. CAF+ALAC versus FLAC against the Section 15 thresholds.
2. Pinned host trust in background URLSession across lock, suspension, system
   relaunch, deferred upload across TLS leaf cutover, and failure.
3. gRPC Swift 2 TransportServices client/server behavior on the chosen iOS and
   macOS floors, including stream cancellation on revocation.
4. Active-master synchronization interval versus durability, energy, and thermal
   behavior on the oldest supported iPhone.
5. Host staging/free-disk defaults using representative one- and three-hour
   recordings.

Spike 1 is a blocking PR 3 exit gate. Spikes 2 and 3 use the disposable signed
`HarcMobileSpikes` target in PR 6. That target is folded into or removed by PR 7;
it never ships. Spikes 4 and 5 complete before their corresponding capture and
staging release gates.

A failed spike changes the implementation behind the frozen domain and security
contracts; it does not weaken local durability, pinning, or receipt semantics.

## 30. Handoff definition of done

This handoff is ready for coding when the implementer can answer every one of
these from this document without inventing a cross-cutting policy:

- Which process owns Host-mode canonical writes? The resident Harc process in V1;
  MCP uses its local adapter and never becomes a second writer.
- What identifies a library, host authority, device, and recording? Section 7.
- What does pairing prove and who approves it? Section 10.
- Which bytes are signed and how are replays handled? Section 11.
- When may the phone delete audio? Only after Section 17's verified receipt.
- Does receipt wait for speech processing? No.
- How does iOS transfer after suspension? Section 13.4 and Section 16.
- How can capture upload concurrently and recover an expired attempt? Section 16.1.
- Which mobile artifacts enter OS backup? None; Section 14.4 freezes the split
  protection and exclusion policy.
- How is Host-mode MCP contained? Section 22's mutually audit-token and
  code-signing-pinned AF_UNIX allowlist.
- Is OKF the wire format? No; it is a portable host projection.
- Does a work Mac process locally? Yes, with Section 20 provenance policy.
- What happens when the host is unavailable? Capture remains local and queued.
- What happens on host migration? New authority and re-pairing in V1.
- What ships first? The PR and release slices in Sections 26 and 27.

## 31. Upstream implementation references

- [gRPC Swift 2](https://github.com/grpc/grpc-swift-2)
- [gRPC Swift Protobuf integration and generator](https://github.com/grpc/grpc-swift-protobuf)
- [gRPC Swift NIO/TransportServices transport](https://github.com/grpc/grpc-swift-nio-transport)
- [Apple AVAudioSession recording category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
- [Apple Bluetooth HFP audio-session option](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp)
- [Apple complete-unless-open file protection](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeunlessopen)
- [Apple background URLSession guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple App Review submission overview](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review)
