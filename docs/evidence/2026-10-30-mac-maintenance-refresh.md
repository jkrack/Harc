# Harc 0.14.20 (75): separate Mac maintenance preparation

Preparation date: October 30, 2026. **Not release-qualified; no publication.**
Base: `ec04ea8329afc02a40555581a3b52c52422c767a`.
Branch: `codex/mac-0-14-20-refresh-20261030`.
The exact pushed preparation head and fresh CI belong in the draft PR checks.

## Identity and scope

Published v0.14.19 (74) remains live. This alternative draft reserves the same
0.14.20 (75) preparation identity as held #155; only one selected, qualified
candidate may eventually use it. Recheck tags/releases before distribution.
#155 at `3c5c07b3b9078f660bc6fe1207b54bb46ab1b32a`, its checkout, diagnostic
bundle and original crash evidence are preserved unchanged. No old test result
is transferred to this new head. This branch changes only version inputs and
preparation documentation; production fixes are already on the recorded base.

The base includes #146's optional auto-paste Accessibility behavior, #154's
Mac Client recovery/status fixes, #157's listener shutdown ordering, #160's
local compiler defaults (CI constraints retained), #164's plan reconciliation,
#167's typed privacy preflight, #168's lost upload-ACK recovery and #169's
receipt-recovery regression after persistence reopen. UI drafts and the MacBook
Trash draft are excluded. No privacy/security or credential configuration changes.

## Proposed release notes (not published)

Harc 0.14.20 improves Mac Client recovery and sync feedback. It avoids false
metadata conflicts for recordings already verified on the Host, separates local
archiving from delivery, and keeps unresolved sync failures visible until verified
completion. Transfers can reconcile an exact chunk accepted by the Host when its
acknowledgment was lost. Network listener shutdown ordering is corrected.
Auto-paste is opt-in and Accessibility is optional; normal finalization does not
automatically request that permission. These are source changes awaiting the
candidate's applicable validation, not a claim that physical recording is qualified.

## Evidence and test matrix

| Evidence | Exact scope | Status / limit |
| --- | --- | --- |
| Held #155 CI, run 40214998656 | `3c5c07b` | Historical pass; not this candidate |
| Held diagnostic signing/startup, October 26 | `3c5c07b`, Debug arm64, development identity | Startup passed; ad-hoc failure retained; capture/Stop unresolved |
| Receipt fail-closed audit, October 30 | unchanged main `ec04ea8` | Parent-reported 57 tests passed; no source change |
| Library/cache audit, October 30 | unchanged main `ec04ea8` | Parent-reported 15 fixtures passed; physical stale-cache cause unresolved; full-resync RPC static review only |
| Candidate tooling, version/readiness, privacy and protocol checks | this branch | PASS locally: 180 Python tooling tests, schema guard, project generation, source/public-URL preflight and 25 relative links |
| Candidate foreground outbox, receipt/store and version regressions | this branch | PASS locally: 37 Swift tests (12 foreground outbox, 22 outbox/receipt persistence, 3 version/display); synthetic fixtures only |
| Full candidate package/macOS/mobile/relay CI | exact pushed head | Required; draft PR checks are authoritative |
| Mac microphone/system audio, visible/hotkey Stop, playback/recovery | final selected source/artifact | OPEN; no capture in this preparation task |
| Developer ID release build, notarization/staple/Gatekeeper and Sparkle bytes | final selected source/artifact | OPEN; development signing is not release signing |
| Phone codec/transfer/receipt/hash/master protection and full Library round trip | sealed phone/Host pair | OPEN; separate from Mac-only maintenance |

Retained local evidence on the Mac mini:
- `/Volumes/MacMiniSDD/HarcBuilds/receipt-fail-closed-audit-20261030/focused.log`
- `/Volumes/MacMiniSDD/HarcBuilds/library-cursor-audit-20261030/focused.log`
- `/Users/jlane/Documents/Codex/2026-10-25/task/harc-pr155-development-signing.json`
- `/Users/jlane/Documents/Codex/2026-10-25/task/published-verification-20261028/verification-result.json`

The October 28 published-artifact verification checked actual public DMG/ZIP
bytes, nested signatures, notarization evidence and live Sparkle signature using
the embedded public key. DMG SHA-256:
`943ba6f92d8bb3779a4edfa3032ad29b9ffb0ff8321655150e1e9c13fdd11285`.
It remains evidence for 0.14.19 only; installed upgrade and physical capture were
not tested. The published release notes explicitly retain an owner waiver of the
affected-Mac audible-recording check. No waiver is inherited by this candidate.

## Next gates

Select the eventual preparation head after fresh checks and review. Resolve the
held diagnostic's pending startup/Stop and owner-reported dialog safely before
any new physical capture; do not infer permission from previous signing approval.
Qualify applicable Mac behavior and the exact final signed artifact, then verify
published bytes/feed in the existing release workflow. Do not merge, sign, install,
publish or submit from this preparation task. Phone App Store remains NO-GO;
archive, privacy/owner fields, screenshots, physical qualification and submission
approval remain separate requirements. Preserve original evidence on refresh.
