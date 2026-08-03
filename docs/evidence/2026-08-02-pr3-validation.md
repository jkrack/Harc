# PR 3 software-foundation validation

**Date:** 2026-08-02

**Status:** Software gates accepted; physical codec gate remains open

## Accepted software gates

| Gate | Result |
| --- | --- |
| `xcodegen generate` | Passed |
| PR 3 focused matrix | 139 tests / 16 suites passed |
| Full `swift test` | 989 Swift Testing cases / 162 suites ran with eight load-sensitive timing issues under concurrent Core ML compilation; the exact affected surfaces immediately passed 97/97 tests in 24 suites in isolation |
| Unsigned resident Mac app build | Passed for macOS arm64 |
| `HarcMobileSpikes` build | Passed for generic iOS Simulator |
| `HarcMobileSpikes` qualification logic | 11/11 tests passed on an iPhone 17, iOS 26.5 Simulator; schema 4 enforces the exact duration/count/format, ordered trial evidence, hashes, bit-exactness, aggregate consistency, physical identity, and measurement thresholds, while simulator and incomplete evidence fail closed |
| iOS client build | `HarcClientStore` passed a generic iOS Simulator build; its exact direct dependencies are `HarcDomain`, `HarcTransfer`, and GRDB, with `HarcIdentity` reachable only through `HarcTransfer` |
| Client module import boundary | Explicit-target dependency import checking passed with no direct `HarcClientStore` dependency/import of `HarcIdentity` |
| External construction boundary | External `swiftc` construction of transport, grant, adoption, and authority-replacement evidence, plus access to the Host internal testing seam, was rejected at package access control |
| SwiftPM resolution normalization | `VersionTests` 3/3 passed; no Sparkle pin remains; expected origin hash updated |
| Patch hygiene | `git diff --check` passed |

The focused matrix covers strict P-256 signing and key lifecycle, grant and
revocation policy, immutable transfer state, both client databases, host
migrations and the three-phase security journal, replay, upload staging,
reconciliation, path safety, quotas, and restart recovery.

## Full-suite qualification

The repository-wide run is not represented as a clean 989/989 Swift Testing
pass. Under concurrent Core ML compilation it reported eight load-sensitive
timing issues across these existing timing-sensitive surfaces:

| Affected surfaces | Full-run issues | Immediate isolated result |
| --- | ---: | --- |
| `SummarizationQueue`, `SummarizationQueueStore`, `PostStopTrayState`, `DictationKeepWarm`, `LibraryMaintenanceStore`, `DictationController`, and `ChunkedTranscriber` | 8 | 97/97 tests passed in 24 suites |

The exact affected group passed immediately after the concurrent model
compilation load cleared. No PR 3 focused test failed.

## Independent audit closure

Independent security and integration passes found and closed these P1 edges:

- initial scope grants that did not require OS authentication broadly enough;
- manifest/receipt evidence that could be forged outside validated packages;
- actor reentrancy around the security-registry high-water transition;
- authority replacement and scope changes that did not fully enforce local OS
  authorization or invalidate prior background capabilities atomically;
- upload-attempt replacement after abandon or expiry, including permanent
  supersession proof that prevents an older attempt from becoming eligible;
- inconsistent authority/grant/device trust facts;
- missing immutable local bytes that could otherwise invite re-encoding under
  an existing descriptor;
- concurrent host chunk writers reconciling or unlinking each other;
- initial grant issuance that was not bound to a live exact-device ticket;
- replay APIs that accepted a precomputed result instead of applying a HostDB
  side effect exactly once;
- a direct `HarcClientStore` → `HarcIdentity` import that violated the fixed
  module graph; validation now crosses the declared `HarcTransfer` boundary;
- codec qualification that sampled only endpoint memory/thermal state and did
  not prove a full three-hour monotonic interval;
- WAL connections whose default `NORMAL` synchronization did not meet the
  power-loss durability boundary; both client stores now restore `FULL` on
  every open and prove it across reopen;
- validator evidence whose tuple could be forged or cross-combined; transport,
  grant, and combined adoption evidence is now package-minted, bound to the
  exact authority tuple and claims, and rejected by an external compiler test;
- upload admission paths that could resurrect an older origin owner or bypass
  the four-active-attempt limit;
- the missing ticket- and OS-auth-bound same-key re-adoption transition,
  including revoked-device new-GrantID recovery, client persistence replay,
  capability invalidation, and all security-journal crash boundaries;
- staging that lacked the two-active-streams-per-device limit and reused a
  request-start timestamp after asynchronous writes;
- authorization, retention, and stream decisions that needed to use only the
  Host trusted clock, including idle revoke, abandon, and scope-change
  termination within five seconds;
- restart reconciliation that could promote a complete pre-ACK `writing` row
  after its exact grant or upload generation had expired;
- reaping that needed a two-phase candidate/current-row validation and
  compare-delete to survive reopen, active-writer, and concurrent-state races;
- codec qualification that treated unavailable Mach memory, unknown thermal
  state, a simulator-compiled binary, or incomplete/synthetic schema-4 evidence
  as eligible measurements.

The final reaper audit found no remaining P0 or P1 issue. Its one P2 immediate
post-reopen retry edge is closed: the host validates and restores an intact
durable pre-unlink claim from an older generation, exact-replays the original
bytes, and leaves the original reaper with no eligible deletion. The focused
matrix passes 139/139, including 28/28 staging tests. The integration pass found
no production listener or network
import, no private keys, raw pairing secrets, or developer secrets, no developer
path leak, and no linkage of the new host/client modules into the resident app.
Standalone Mac capture and publication remain on the existing PR 2 path.

## Codec gate still open

The schema-2 accelerated simulator diagnostic completed ten of ten chunks
bit-exactly and proves only that both native Apple codec paths work in the
harness. It is not physical performance evidence.

The checked-in harness now emits schema 4 evidence. Measurement availability,
compile-time simulator identity, iOS-app-on-Mac state, interface idiom, and an
exact physical iPhone hardware identifier are explicit and mandatory for a
candidate/device pass; the older schema-2 diagnostic remains historical and
nonqualifying.

No physical iPhone was attached to the build host. Therefore the release codec
is deliberately **not selected**, and PR 5 production decode/commit must remain
codec-neutral until the following reports exist:

- CAF+ALAC and FLAC;
- fresh-process signed builds with an exact 40-hex source commit;
- one report per candidate on the named oldest-supported and current iPhones;
- 180 ordinary 60-second boundaries and at least 10,800 monotonic and wall-clock
  seconds;
- bit-exact decoded canonical PCM;
- p95 encode below 10 seconds, queue depth at most two, incremental peak memory
  below 100 MiB, and no serious or critical thermal observation.

Each report qualifies only one candidate/device pair. Simulator output or one
successful phone run cannot freeze the production codec. PR 4 may proceed using
the codec-neutral contract while this gate remains open, but PR 3 cannot exit
and PR 5 production codec selection/decode/commit cannot proceed until it closes.
