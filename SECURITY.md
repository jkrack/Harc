# Security

Harc uses private inference. Standalone mode captures, transcribes, and
summarizes audio on the current Mac. In Client mode, recordings and derived
artifacts can synchronize automatically to the explicitly adopted Harc Host.
HarcMobile captures locally and transfers to that adopted Host for processing.
A Host owner can enable Harc Remote for encrypted connections across networks.

## What talks to the network

- **Model downloads** — one-time fetches from Hugging Face over HTTPS.
  Harc's own downloads (summarizer tiers) are pinned to immutable revisions
  and verified per-file against SHA256 before install. The speech models are
  fetched by the FluidAudio library's own downloader; Harc trusts its
  integrity checks (a documented third-party trust boundary).
- **Updates** — Sparkle 2 checks a signed appcast over HTTPS. Releases are
  EdDSA-signed; Sparkle refuses unsigned or mis-signed updates. System
  profiling is permanently disabled — the update check sends nothing about
  you or your machine.
- **Adopted Host connections** — authenticated encrypted transport carries
  recordings, transcripts, Library information, and speaker synchronization
  between adopted devices. Bonjour discovers candidate routes; discovery never
  establishes trust.
- **Harc Remote (opt-in)** — a content-blind relay connects clients and Hosts
  across networks. Application content remains inside pinned TLS. The relay
  infrastructure can observe connection metadata; encryption is not a claim
  that the infrastructure observes no metadata. Deployment logging, exports,
  and retention must be checked against the exact release's privacy assessment.
- **User-directed export** — a user can explicitly export a selected recording
  through a system destination outside the adopted-Host boundary after Harc
  identifies that boundary. This is not an automatic synchronization path.

Harc does not use cloud inference or an external application telemetry, crash
reporting, or analytics service. Production relay configuration and account-level
retention are separate operator checks documented in
[`docs/operations/app-store-release-readiness.md`](docs/operations/app-store-release-readiness.md).

The bundled `harc-mcp` executable (the MCP agent bridge) speaks JSON-RPC over
stdio to the user's MCP client (Claude Desktop, Claude Code, etc.). In
Standalone mode it accesses the local store and notes. In Host mode it uses
authenticated local IPC to the resident Harc app; it must not fall back to direct
canonical database writes when the Host is unavailable. Content returned to an
MCP client is available to that client and its configured model provider; the
MCP client's own network and data-handling policy applies.
Note that because harc-mcp is spawned by the agent host/MCP client process,
writes to the notes folder under `~/Documents` are TCC-attributed to that
process — if the user denied it Documents access, OKF file regeneration
silently no-ops (database writes in Application Support are unaffected).

## Adopted-device trust boundary

Harc's host/client architecture permits an iPhone or secondary Mac to
send recordings and derived artifacts to an explicitly adopted, user-controlled
Harc host. This remains private/local-first behavior, not cloud processing.

The implementation contract requires these boundaries:

- No Harc-operated cloud speech, diarization, summarization, telemetry, crash
  reporting, or analytics service.
- Pairing requires local approval on the host and establishes a separate,
  revocable key identity for each client.
- Audio moves automatically only over authenticated encrypted transport to the
  adopted host. A foreground, user-directed system export may send a selected
  recording elsewhere after Harc discloses that the destination is outside the
  adopted-host trust boundary; Harc never schedules that export automatically.
- The client writes and retains a durable local master until it stores a signed
  receipt proving that the host committed the canonical audio.
- Mobile masters, transfer derivatives/state, and downloaded host cache are
  protected and explicitly excluded from OS device backup. Reinstall/restore
  requires re-pair and cache resynchronization; unuploaded recordings remain
  recoverable only from the physical source device or an explicit user export.
- The host is the sole authority for its library database and portable
  WAV/JSON/OKF projections; clients never open or copy the host database.
- Bonjour, hostnames, IP addresses, VPN membership, and physical network
  proximity are discovery or reachability signals only. None establishes trust.
- Revocation is enforced against current host registry state on every new
  operation and active transfer, rather than relying only on a previously
  issued signed grant.
- In Host mode, the bundled `harc-mcp` reaches the canonical store only through
  authenticated same-user local IPC owned by the resident Harc process. It does
  not fall back to direct writes while that host is unavailable.

The approved cryptographic, pairing, authorization, revocation, and retention
contract is specified in
[`docs/specs/2026-08-02-host-client-mobile-implementation-spec.md`](docs/specs/2026-08-02-host-client-mobile-implementation-spec.md).

## Accepted trade-offs

- **No App Sandbox.** Harc needs Accessibility (insert-at-cursor),
  ScreenCaptureKit (system audio), a user-chosen recordings folder, and a
  spawned STT daemon over a Unix socket — a sandboxed rearchitecture
  (security-scoped bookmarks, XPC daemon) is possible but not done.
  Hardened runtime is enabled.
- **Same-UID IPC.** The daemon socket (`~/.harc/stt.sock`) is `0600` inside
  a `0700` directory and verifies the connecting process's UID. Requests can
  reference any file the user can read — no privilege boundary is crossed.
- **Deep links are gated.** `harc://dictate` never opens the microphone
  without explicit confirmation (unless Harc itself is frontmost), and a
  transcript is never inserted into the app that delivered the link.

## Where data lives

- `~/Documents/Harc` — recordings + transcripts (user-visible)
- `~/Library/Application Support/Harc` — library DB, modes, dictation
  history (plain JSON), summarizer models
- `~/Library/Application Support/FluidAudio/Models` — speech models
- `~/Library/Caches/Harc` — recording cache, daemon log (no transcript
  content or recording paths are logged)
- `~/.harc` — daemon socket

## Reporting

Open a GitHub issue, or email the address on the maintainer's profile for
anything sensitive.
