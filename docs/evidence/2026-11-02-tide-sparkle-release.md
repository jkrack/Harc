# Harc 0.14.20 (75): Tide Sparkle release evidence

Recorded November 2, 2026. The owner requested a new Sparkle release containing the Tide fidelity pass and confirmed the final physical shortcut check before publication.

## Source and scope

The app embeds `HarcBuildSHA=a5a60ff42c92020eb0d46abd93ff5d7f4c19bd3a`.
It combines main `ccc6bad4388dfe20e608abac25213fe6a29f2eae` and Tide `49a5c891c06cae391b11fbbe14498bc12f0152a9`, followed by two mobile UI assertion corrections. The corrections expect Tide's omitted empty timeline and allow 0.001 point of coordinate roundoff.

[Tide PR #174](https://github.com/jkrack/Harc/pull/174) merged into its requested `claude/jolly-lamport-ei6djr` base. [Release integration PR #175](https://github.com/jkrack/Harc/pull/175) merged into main as `c3ddb2559ee46e8a548d4f373e8d390d8df125b5`. That merge's tree is exactly the tested and packaged source tree, `64b6a8f3797f58f60190612ea5baef15ff724193`. The subsequent release commit changes only this evidence, the preparation-record pointer and appcast metadata; it does not rebuild or alter the app.

The fidelity report retains [38 before/after pairs, the gap table and original diagnostic results](../design/tide-2026-10-19/verification/fidelity-gaps.md). Those images describe their recorded source. This release's current-source automated evidence is below. Held draft #155 and its earlier candidate remain unchanged; only this qualified 0.14.20 (75) candidate is distributed.

## Exact packaged artifact

| Field | Verified value |
| --- | --- |
| App | Harc 0.14.20 (75), `com.harc.Harc` |
| Architecture | arm64 app, harc-stt and harc-mcp |
| Developer ID team | `63TNU5M7P4` |
| Notarization | Accepted, `a03454e0-3f1f-4873-a7c9-b9efa658f4ba` |
| DMG bytes | 51,432,866 |
| DMG SHA-256 | `f4e1ae5d6cec8c1b8d631392ee850b2906ef2d1496f55e69d2fb851ce77b5880` |
| ZIP bytes | 48,713,802 |
| ZIP SHA-256 | `e77faeebe35748e22024f78087929d66ad4d83c6393694da906076a6c486d6cb` |
| Resolved Sparkle | 2.10.1, `ab7d71291238df6e0492143b120c9b696a35f603` |

`verify-release.sh` passed the DMG and nested signatures, stapled ticket, Gatekeeper, embedded source, bundle identity, version/build and architecture checks. The ZIP contains the identical stapled `Harc-local.dmg` at its root. An independent CryptoKit check verified the Sparkle Ed25519 signature against the public key read from the packaged app; its feed URL matches production. No signed asset was rebuilt, resigned or restapled afterward.

## Automated validation

[Exact-source CI run 41363153782](https://github.com/jkrack/Harc/actions/runs/41363153782) passed all applicable PR jobs: package/build, relay, Mac app/UI, mobile configuration and mobile diagnostics. Push-only smoke was skipped on the PR as configured.

| Suite at a5a60ff | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Package Swift Testing | 1,849 | 0 | 0 |
| Package XCTest | 169 | 0 | 7 |
| Mac app | 78 | 0 | 0 |
| Mac UI | 13 | 0 | 0 |
| Bounded mobile configuration execution gate | 89 | 0 | 0 |
| Local focused mobile UI regression rerun | 2 | 0 | 0 |

The bounded mobile gate includes app and selected UI tests; it is not the full physical-phone suite. The original fidelity report contains the full simulator suite and its physical-only skips. On the integration tree before the test-only corrections, 190 tooling tests, protocol schemas, project generation and whitespace checks passed.

Earlier a92ed71 CI failed the two mobile expectations corrected above. An unsigned local simulator attempt could not access fixture controls, failed two tests and stalled during teardown; it was terminated and retained. The properly ad-hoc-signed focused rerun passed both cases. These attempts are not pooled into a single green count. The final source's full Mac CI passed all 91 app/UI cases, separately from the earlier fidelity diagnostic's SIGKILL and isolated retry.

## Final-candidate physical check

The exact notarized app was launched in Standalone mode with a disposable Foundation home and destination, automatic updates disabled, auto-paste disabled and pre-roll disabled. Visible Record/Stop, durable save and in-app playback passed with a 14.48-second, 231,680-frame, 16 kHz mono file containing nonzero audio. Playback progression was observed at 0:04 and 0:08.

On November 2 the owner pressed physical Control-Option-R to start and stop and confirmed both worked. The same disposable library contains the resulting 7.14-second, 114,240-frame, 16 kHz mono file with nonzero audio. The same candidate's runtime log records capture starting and returning to idle. The temporary app and its daemon subsequently exited; the original app was not running before these checks and remains stopped. Earlier a92ed71 clips are retained separately as historical evidence.

Raw QA audio and transcripts remain local and are not included in the repository or release. Foundation home isolation does not isolate every macOS UI preference; normal window and selection preferences may persist. An earlier isolated Host launch failed closed on the protected Library/key binding. No protected Host key was replaced or production recording destination rebound.

These short checks do not qualify long-session endurance, physical power loss, separately isolated microphone/system-audio routing, secondary-Mac delivery, phone pairing/transfers, physical Live Activity or App Store readiness. Timestamped summary pins still need a data contract. Several same-minute recordings lasting 0 to 1 seconds remain visible and are reported as a possible capture-start failure; the presentation pass does not diagnose that path.

## Publication verification

The release uses an annotated `v0.14.20` tag and both `Harc-local.dmg` and `Harc-local-dmg.zip`. Publication is ordered so the signed feed is pushed to main only after both GitHub assets exist and their API digests and independent public downloads match the hashes above. The live raw appcast, enclosure URL, version/build and main/tag provenance are then checked. Final remote verification receipts are retained on the Mac mini SSD under `HarcBuilds/tide-sparkle-20261101`; the [GitHub release](https://github.com/jkrack/Harc/releases/tag/v0.14.20) records the publication outcome.
