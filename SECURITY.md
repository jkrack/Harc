# Security

Harc is a local-first app: audio is captured, transcribed, and summarized
on-device. Nothing about you or your content leaves this Mac.

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
- Nothing else. No telemetry, no crash reporting, no analytics.

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
