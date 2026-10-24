# Harc 0.14.20 (75) Mac maintenance preparation

Date: 2026-10-24. **NO-GO for publication. No artifact selected.**
Initial base: `2e8711e7af54d58d6716b4301e0d3eec9aa40fd3` (merged #154).
Previous base: `206ba922487b84b02ecae24240815068a83f8335` (merged #153).
Current base: `2c9d3fd47bf65b17a2c373b2e62cfd154b4bdc85` (merged #157 and #156).
This separate preparation changes version/fallback/readiness inputs, this
record and a focused readiness-row regression. It does not qualify hardware or authorize distribution.

## Identity and scope

Git fetch and remote heads/tags, the connected GitHub release listing, open-PR
search/details and main appcast were checked before changing inputs. Latest
published release is 0.14.19 (74), tag source
`befd4e9fc4cfb1fccd7f0123e81e1785f44891f2`. Its DMG metadata reports 51,301,863
bytes, matching the feed, and SHA-256
`943ba6f92d8bb3779a4edfa3032ad29b9ffb0ff8321655150e1e9c13fdd11285`.
This is metadata reconciliation, not downloaded-byte/signature verification.
No 0.14.20 release/tag was listed; all 58 fetched remote project configurations
were at build 74 or lower. Thus 0.14.20 (75) is the next unused preparation
identity in the inspected repository evidence. Recheck before any later release.

At initial inspection, open #146 (`codex/recording-permission-flow`) and draft #153
(`codex/mobile-route-failure-regression`) were authored by `jkrack`. They were
excluded; their files/branches were not edited. #153's active continuation
investigation remained with its owner at that point. Accessibility alerts addressed by #146
remain unresolved in this candidate; do not claim their fix.

Before final validation, #153 merged normally into main as
`206ba922487b84b02ecae24240815068a83f8335`. This preparation then merged that
main commit without conflicts. The combined source now includes its phone route
continuation fix and validation diagnostics; the earlier exclusion describes the
initial base only. The phone fix completes a dequeued route request when writer
checkpointing fails and establishes ordering in its regression. It is source
software evidence, not physical capture/route qualification. At that checkpoint,
#146 and then-unmerged #156 remained excluded. Earlier-head CI applies only to
its recorded source.

The later refresh integrates actual main
`2c9d3fd47bf65b17a2c373b2e62cfd154b4bdc85` without conflicts. It includes #157's
NIOTS listener-close ordering fix and #156's truthful phone Library refresh/error
presentation and contextual recovery navigation, as well as #153. These merged
changes are source inclusion, not physical listener lifecycle, Library recovery,
phone capture or release qualification. #146 remains excluded. Search work is
local and excluded; no search change or publication approval is inferred.

Version availability was rechecked on this refresh: published releases and the
main feed still top out at 0.14.19 (74), no 0.14.20 tag/release exists, and among
61 fetched remote project configurations only this preparation branch uses
0.14.20 (75). The reserved preparation identity remains unchanged. New final-head
CI is required; prior preparation CI is historical evidence only.

Since published 0.14.19, #154 adds actual Mac runtime value: exact transfer-store
Date-codec normalization avoids false Host-only recovery conflicts; foreign
identity, filename and changed metadata still fail closed. Archive completion is
reported independently of delivery. Per-recording sync failures survive retries
and clear only from scoped durable completion evidence; a successful empty scan
does not imply delivery. This justifies a small maintenance candidate, subject
to all remaining gates. #145 reconciles readiness inputs; #147–151 (via #152)
harden validation, signer identity, TLS restart qualification, relay privacy checks
and metadata checking. These are supporting preparation improvements, not new
capture or phone qualification. #142 documents existing Omega blockers. #157
adds Mac runtime value by closing Network-framework listeners through their NIO
channel before cancellation, including the late-registration path, while retaining
bounded runtime joins. This addresses a process-crash ordering hazard, not a
claim of hardware or endurance qualification.

## Proposed release notes

Harc 0.14.20 improves Mac Client recovery and sync feedback. It avoids false
metadata conflicts when recovering recordings already verified on the Host,
reports local archiving separately from delivery, and keeps unresolved sync
problems visible until the affected recording has verified completion. It also
fixes a network listener shutdown ordering issue that could crash the process.

## Preparation validation and limits

The Linux x86_64 cloud environment has Python and Node, but no Swift, Xcode,
xcodegen, plutil or Apple signing/trust services. No Mac was contacted.
Before input edits, all 159 Python tooling tests passed; focused readiness (6),
release verifier (4) and package-resolution (16) regressions also passed.
Protocol guard passed: seven schemas, six services, 27 RPCs, 31 enums.
Post-edit results and exact pushed-head CI are recorded in the draft PR.

Aggregate repository smoke stops at missing `xcodebuild`; xcodegen generation
and Swift VersionTests/app tests cannot execute locally. The source/public-URL
preflight exits 1 with 27 open items because Apple plist/image tools are missing;
these are environment failures, not established source defects. Both public URLs
returned HTTP 200 and support contact matching passed. No archive, exported app
or screenshots were supplied. Keep the failure; rerun on the authorized Mac.

## Remaining Mac qualification and artifact work

The authorized MacBook is offline; other Macs are not authorized. The following
is a handoff only, not permission to operate another machine or sign/publish.

1. On an available authorized Apple Silicon Mac with existing compatible Xcode,
   Swift, xcodegen, SDKs and at least 5 GiB working headroom, check out the exact
   reviewed pushed source, regenerate with `xcodegen generate`, and run focused
   `HarcDesktopClientRecoveryTests`, `HarcDesktopSpeakerReviewCoordinatorTests`,
   `ClientHostConnectionStateTests`, `HarcTransportErrorDiagnosticTests` and
   `VersionTests`, plus focused `GRPCListenerCancellationIntegrationTests` and
   `BackgroundUploadListenerRuntimeV1Tests`, full package, both direct and relay
   pinned-TLS lifecycle gates, Mac app/UI and repository smoke checks.
   Required PR CI also includes mobile configuration and credential-free relay.
2. Against the exact candidate on authorized affected hardware, record audible
   microphone capture with the selected input, route removal/reconnect, no-frame
   startup and microphone/system-audio behavior. Exercise visible Stop and hotkey
   Stop, prompt acknowledgement, durable finalization, playable complete audio,
   transcript delivery, and restart/force-quit recovery. The prior 0.14.19
   affected-Mac audible test waiver does not qualify this candidate. Check
   missing-master Host-only recovery, codec-normalized metadata, changed/foreign
   evidence rejection, retained failure feedback, independent archive/delivery,
   transient inventory failure and verified per-recording clearance after retry.
   Preserve protected masters and evidence; never reset state to obtain a pass.
3. Client/Host qualification requires two separately authorized Macs with the
   same signed source/app bytes and real direct/two-network relay paths. Follow
   `docs/operations/secondary-mac-qualification.md`: three complete passes of
   pairing, offline/relaunch, route change, sleep/wake, Host restart, concurrent
   capture/upload, Host load/fallback, speaker sync/conflict, revocation and
   relay/direct recovery. Record latency, discontinuities, stalls and hashes.
   No such pair is currently authorized; this physical gate remains open.
4. After applicable gates and separate authorization, build a clean Release
   using `./scripts/build-release.sh` (two workers), existing Developer ID
   Application identity/private key, hardened runtime and secure timestamps.
   Retain full source SHA, dependency resolution (including official Sparkle
   version/revision), executable/helper hashes and build evidence. Do not ship
   ad-hoc `build-local.sh` output or commit generated Sparkle lockfile churn.
5. Existing `harc-notary` login-Keychain profile and Apple network access are
   required for `xcrun notarytool submit build/release-dist/Harc-0.14.20.dmg
   --keychain-profile harc-notary --wait`, then `xcrun stapler staple` that DMG.
   Run `./scripts/verify-release.sh 0.14.20 75
   build/release-dist/Harc-0.14.20.dmg` from a normal macOS terminal with trust
   services: exact source/version/build, bundle IDs, expected Developer ID/team,
   app/nested/DMG signatures, hardened runtime, arm64 app and both helpers,
   checksum, stapled ticket and Gatekeeper must pass.
6. Only after stapling, copy to `Harc-local.dmg`; create `Harc-local-dmg.zip`
   using `ditto -c -k --sequesterRsrc`. Existing Sparkle EdDSA key in the login
   Keychain and Sparkle tools are required for `./scripts/make-appcast.sh
   0.14.20 75 build/release-dist/Harc-local.dmg`. Verify against the app's pinned
   public key; retain exact DMG bytes, signature, length and SHA-256. No keys
   were accessed and no credentials were created/configured in this task.
7. Future publication needs separate authorization: upload both assets, verify
   downloaded DMG and ZIP-contained DMG equal the stapled signed bytes, verify
   feed version/build/minimum OS/enclosure URL/length/EdDSA signature and actual
   asset availability, then verify update from the published baseline. Main
   serves the live feed: never expose an entry before its exact asset exists.
   This preparation leaves appcast, releases and tags unchanged.

## Shared iPhone consequences

`project.yml` supplies the same marketing/build values to Mac, iPhone and widget.
The phone readiness header is therefore aligned to 0.14.20 (75) for identification
only. Sealed release source remains unselected and App Store decision remains
NO-GO. The merged #153 source fix is included through current main; it does not
imply physical continuation/route qualification. No codec enablement, physical
capture/transfer receipt,
protection/reliability/upgrade/accessibility pass, archive/export, privacy owner
approval or submission follows from this bump or hosted CI. Follow the current
companion launch plan and mobile physical/App Store runbooks; preserve all dated
evidence identities. Merged #156 Library recovery UX is included as source work
only; repeat affected physical Library failure/retry/navigation checks. #157
listener teardown also needs affected real Host restart/route recovery checks.
Local search work remains excluded.
