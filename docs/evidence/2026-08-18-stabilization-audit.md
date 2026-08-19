# Harc repository stabilization audit

**Date:** 2026-08-18

**Reviewed base:** `811a465a1ac95333bbc7e17adb0773a05f3a6758`

**Source version:** Harc 0.14.3 (58)

## Decision

**GO for the current repository and macOS development baseline.** The living
documentation now matches the implemented SwiftPM/Xcode targets, the complete
Swift package regression and macOS app build pass, and the retained published
0.14.3 DMG passes the release verifier.

This is not an iPhone App Store submission GO. Repository-side HarcMobile
preflight passes, but the retained local archive is historical 0.14.1 (56)
evidence. A current submission requires a new exact-build 0.14.3 (58) archive
and the still-open external physical-device and App Store Connect gates.

## Reconciliation and fixes

- Updated the README download/status copy from 0.14.0 to the current 0.14.3
  release while preserving the separate HarcMobile distribution boundary.
- Updated `AGENTS.md` to reflect implemented Host, Client, Remote transport,
  and mobile-audio targets. Only `HarcAudioMac` and `HarcInference` remain
  documentation-only boundaries.
- Corrected `HarcVersion.fallbackVersion` from 0.14.1 to 0.14.3 after the full
  regression caught its deterministic mismatch with `project.yml`.
- Replaced deprecated MCP content constructors and macOS activation APIs, and
  removed an accidental `@ViewBuilder` annotation from a string formatter.
- Removed the tracked zero-byte `default.profraw` artifact and added a matching
  ignore rule.

Dated evidence files were not rewritten. Older support placeholders and
candidate status statements remain accurate historical snapshots; newer
evidence records the resolved public support contact.

## Validation

| Gate | Result |
| --- | --- |
| Focused recovery/readiness/mobile-transfer tests | 43 tests in 5 suites passed |
| Initial full Swift package run | 1,553 tests in 261 suites; one deterministic version mismatch found |
| Focused version contract after fix | 3 tests in 2 suites passed |
| Final full Swift package run | 1,553 tests in 261 suites passed |
| Focused version, menu-bar, and MCP adapters | 14 tests in 3 suites passed |
| Final HarcTools constructor check | 11 tests in 1 suite passed without the local MCP deprecation warning |
| macOS `Harc` Debug app build | `BUILD SUCCEEDED` with two Xcode build workers, including embedded `harc-stt` and `harc-mcp` |
| HarcMobile repository preflight | Passed |
| Published macOS 0.14.3 (58) DMG | Passed signature, notarization/staple, Gatekeeper, nested-code, version/build, relay-origin, arm64, byte-count, and SHA-256 checks |
| Final disk floor | Approximately 13 GiB free, above the 5 GiB operational stop floor |

The final Xcode build emits only the metadata processor's informational warning
that no AppIntents framework dependency exists. The Harc-source deprecation and
result-builder warnings found during the first build were removed.

## Release-artifact disposition

| Artifact | Disposition |
| --- | --- |
| `build/release-dist/` (187 MiB) | Keep. It contains the verified published 0.14.3 DMGs and ZIP. |
| `build/app-store/` (373 MiB) | Keep as historical 0.14.1 archive/export evidence. It is not a current 0.14.3 candidate. |
| `build/release-derived/` (4.7 GiB) | Removed. It was ignored, rebuildable release DerivedData. |
| `Harc 2.xcodeproj` through `Harc 19.xcodeproj` (2 MiB total) | Removed. They were ignored numbered copies; canonical `Harc.xcodeproj` remains. |
| `.build/` and `.build-daemon/` | Keep warm on this constrained Mac for incremental Swift and embedded-helper builds. |

The report-only inspection of the historical iOS archive correctly rejects its
0.14.1 (56) version/build against current 0.14.3 (58). Other archive-signing
opens from that restricted report-only pass do not supersede the dated
exact-archive evidence; the version/build mismatch alone makes it non-current.

## Remaining release boundaries

- Create and verify a clean exact-build HarcMobile 0.14.3 (58) archive before
  any current App Store upload claim.
- Complete the named physical iPhone codec and C/T/P/H matrix.
- Complete the real secondary-Mac acceptance flow.
- Complete the remaining physical two-network/direct-route/revocation evidence
  and Account Holder/App Store Connect decisions.
