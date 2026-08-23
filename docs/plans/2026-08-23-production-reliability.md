# Harc production reliability and App Store closure plan

**Date:** 2026-08-23

**Reviewed base:** `87dfe849554864bb9c2ade3841b6ee95496969dc`

**Decision:** **NO-GO for production/App Store submission until the named
external gates pass.** The current architecture is viable and the repository
software gates are strong, but Simulator, one available Pro iPhone, and local
transport emulators cannot qualify the oldest/current-non-Pro device matrix,
real secondary Mac, two-network operation, or App Store distribution service.

## Product operating model

Harc should feel like one local recording utility even when a Host exists:

1. The capturing Mac starts durable audio immediately and remains useful
   offline.
2. A macOS Client performs transcription, diarization, and local Library
   recovery itself. Host delivery is an independent durable queue.
3. The Host authenticates canonical audio and Client artifacts, maintains the
   canonical Library and shared speaker profiles, and performs derived work only
   when the Client result is absent/incompatible and the Host has spare cycles.
4. Every visible status is a fact: trust, route, authenticated session,
   recording delivery, processing delivery, and speaker sync never collapse
   into a misleading single “paired” state.

## Benchmark research translated into requirements

The closest current references are MacWhisper/Whisper Transcription and Wispr
Flow. MacWhisper's official product surface emphasizes native macOS recording,
local transcription, batch work, and automatic speaker recognition. Wispr's
support material explicitly describes retrying pending audio after network
reconnection or wake. Harc should match those low-friction expectations without
copying their privacy boundary: private local inference and the adopted Host
remain non-negotiable.

- MacWhisper: <https://www.macwhisper.com/>
- Whisper Transcription App Store surface:
  <https://apps.apple.com/us/app/whisper-transcription/id1668083311?platform=mac>
- Wispr Flow audio recovery guidance:
  <https://docs.wisprflow.ai/articles/3089221553-troubleshooting-notetaker-recording-and-audio-beta>
- Apple local-network privacy technote:
  <https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>
- Apple App Review Guidelines:
  <https://developer.apple.com/app-store/review/guidelines/>

The resulting experience requirements are:

- capture acknowledgement must not wait for model warmup;
- recording safety must remain independent from optional inference;
- a route change, wake, relaunch, or transient inference failure must wake
  bounded retry automatically;
- unresolved work must be inspectable and repairable, never silently dropped;
- speaker recognition must expose no-match, pending-review, and local
  diarization failure as distinct concerns; and
- background repair must yield to active capture so reliability work never
  makes the recording experience rough.

Apple's current guidance reinforces two release requirements: Bonjour browsing
must be tested on physical hardware with truthful local-network permission copy
and connectivity-aware retry, and every microphone/screen recording path needs
explicit consent plus a clear visual or audible recording indication. Simulator
network behavior cannot close the physical local-network gate.

## Reliability work completed in this candidate

- Transcript coverage is explicit. Exhausted chunk failures create visible
  ranges/markers; audible empty-VAD chunks receive a no-VAD retry.
- Desktop capture begins before STT warmup and records capture/inference latency
  separately.
- Client outbox retry is persisted, bounded, restored across relaunch, and
  triggered by network recovery and system wake. Processing/speaker-only work
  keeps retry alive after audio is committed.
- Saved direct/relay route failure can use Bonjour only when the candidate
  proves the adopted Host authority. Desktop selection now tries authenticated
  direct, authenticated Bonjour repair, then encrypted relay, so a healthy
  relay cannot pin the Client to a stale LAN address.
- Desktop and mobile clients classify authenticated grant rejection as explicit
  pairing repair instead of ordinary reachability failure. Automatic probes
  pause at that terminal trust state; protected masters remain local until a
  foreground re-pair changes adoption.
- The macOS Client performs an authenticated idle health check every minute,
  yielding to capture and queued transfer work. It repairs moved Host routes
  even when no recording is waiting.
- HarcMobile now uses the foreground-pairing adoption transition for re-pair,
  exposes a local-only Forget This Host action, and distinguishes pairing repair
  from Desktop unavailable in both visual and accessibility status.
- A proved pairing claim can resume over a fresh authenticated connection
  without changing ticket, authority, expiry, or SAS. Cancellation/rejection
  invalidates suspended continuations, and closing an already-paired window no
  longer displays an unpaired state.
- HarcMobile now applies the same resume contract during Host approval: a
  transient RPC loss re-authenticates the original direct/relay route, then
  authenticates Bonjour repair candidates against the exact original ticket.
  It preserves the proved claimant material and never generates replacement
  security words during recovery.
- Both clients enforce the signed pairing-claim expiry locally, so a Host stuck
  at pending cannot leave approval spinning beyond the invitation deadline.
- Host/client health is rendered as independent trust, route, session,
  recordings, processing, speakers, and last-authenticated-contact facts.
- Client processing artifacts carry complete coverage and Host-bound completion
  evidence. Failed local diarization is durable, truthfully labeled, visible as
  a speaker concern, and retried from the protected master.
- Host waits briefly for a desktop Client artifact, admits fallback work only
  under healthy thermal/power/load/no-capture conditions, and retries transient
  processing failures in-process with bounded backoff. Canonical artifact
  binding changes remain fail-closed.
- Host staging maintenance runs at startup, every six hours, and after wake with
  coalescing and privacy-bounded diagnostics.

## Closure gates

| Gate | Release requirement | Current disposition |
| --- | --- | --- |
| Software regression | Full Swift package suite, macOS Xcode app target, focused Host transport suite, direct and relay pinned-TLS lifecycles | **Passed on the reviewed working tree:** 1,577 tests in 266 suites with two declared MLX environment skips; focused macOS/iOS app and Host-maintenance suites passed; bounded arm64 macOS Xcode build passed; direct and relay pair/authorize/revoke/forget/re-pair lifecycles passed |
| UI/software accessibility | Complete current-tree Simulator UI suite with no findings | Passed; exact xcresult is retained in ignored qualification output |
| Physical iPhone UI | Real microphone, storage protection, force-quit recovery, storage exhaustion, VoiceOver/largest text | Open; three bounded signed Omega runner attempts timed out enabling automation before executing a Harc test |
| Codec/endurance | Four real-time three-hour cells on iPhone XR/iOS 18 and current non-Pro iPhone 17/current iOS | Open; no substitute hardware evidence is accepted |
| C/T/P/H matrix | All spec scenarios, with three consecutive C1/C2/T1/T2 passes per named phone | Open |
| Secondary Mac | Pair, reconnect after route change/wake, process locally during Host load, upload concurrently, surface Host/speaker decisions | Open; repeatable privacy-bounded collector and three-pass physical runbook now checked in |
| Two-network/relay | Physical direct/relay failover, replacement session, visible revocation, no plaintext/content retention | Local/emulator and staging evidence exists; final physical path is open |
| App Store artifact | Clean sealed commit, Release archive/export, exact-build screenshots, TestFlight processing, owner metadata/privacy/export answers | Open; the app now seals its source commit and preflight rejects archive/export commit mismatch |

## Latest bounded validation

The mobile claim-recovery change passed 22 focused bootstrap/pairing tests and
9 authenticated route-strategy tests, including replacement-transport resume,
exact-deadline expiry, cancellation safety, authenticated Bonjour precedence,
and relay fallback. An unsigned arm64 `generic/platform=iOS` HarcMobile Debug
build completed successfully with two Xcode workers. The repository App Store
preflight, including the public privacy-policy and monitored support URLs,
passed afterward. `Package.resolved` was restored to the committed SwiftPM
state and verified at SHA-256
`106ebee1454e4c50466364ac2552284dc168e705f80f786a48e371471bea8414`.

## Execution order

1. Seal a candidate commit and run the physical matrix without source changes.
2. Qualify a real secondary Mac and two-network direct/relay recovery against
   the same sealed source.
3. Produce the exact Release archive/export and screenshots, upload to
   TestFlight, inspect processing warnings, and complete Account Holder fields.
4. Any failure reopens the candidate. Fix, reseal, and repeat affected gates;
   never transfer evidence from an older build to new bytes.
