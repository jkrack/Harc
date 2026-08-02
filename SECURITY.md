# Security

The current Harc release is a local-first Mac app: audio is captured,
transcribed, and summarized on the Mac. It has no adopted-device transport yet,
so nothing about you or your content leaves this Mac through Harc.

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
- **Current release:** nothing else. No telemetry, no crash reporting, no
  analytics.

The bundled `harc-mcp` executable (the MCP agent bridge) opens **no network
connections**: it speaks JSON-RPC over stdio to a locally spawned agent host
(Claude Desktop, Claude Code, etc.) and touches only the Harc database in
Application Support and the user's chosen notes folder. Any network traffic
in that flow belongs to the agent host the user runs, on their own account.
Note that because harc-mcp is spawned by the agent host/MCP client process,
writes to the notes folder under `~/Documents` are TCC-attributed to that
process — if the user denied it Documents access, OKF file regeneration
silently no-ops (database writes in Application Support are unaffected).

## Adopted-device mode (approved, not yet implemented)

Harc's approved host/client architecture permits an iPhone or secondary Mac to
send recordings and derived artifacts to an explicitly adopted, user-controlled
Harc host. This remains private/local-first behavior, not cloud processing.

The implementation is required to preserve these boundaries:

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

Until that architecture ships and this document's network inventory is updated,
the current-release description above remains the behavior users receive.

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
