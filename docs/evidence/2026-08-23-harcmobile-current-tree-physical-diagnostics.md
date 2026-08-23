# HarcMobile 0.14.10 current-tree physical diagnostics

**Date:** 2026-08-23

**Source baseline:** `87dfe849554864bb9c2ade3841b6ee95496969dc` plus uncommitted reliability work

**Configuration:** HarcMobile 0.14.10 (65), signed Development build
**Device:** Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6 (23G71), arm64

## Qualification interpretation

This is current-working-tree diagnostic evidence, not sealed release evidence.
It proves that the hosted app logic and the physical-spike harness guards run on
the available iPhone. It does not complete a real-time three-hour codec cell,
the named oldest/current-non-Pro device matrix, a clean archive, or App Store
distribution signing.

## Results

| Bundle | Result | Preserved xcresult archive SHA-256 |
| --- | --- | --- |
| `HarcMobileAppTests` | **39 passed**, zero failures/skips | `9c4305228c6ccbfb46b2c2d4dabd3e557cfb4a32e38c16b908eb9df025be77a1` |
| `HarcMobileSpikesTests` | **14 passed**, zero failures/skips | `86253cf65cea529ae833c7f25310957a07f7b1effb0da6390a9ca57131be23ba` |
| `HarcMobileUITests`, attempt 1 | **No tests executed**; runner initialization timed out enabling automation mode | `fe234e89b7c19d29af6dd8f012ab08d24daa32c46466a56ab68a0349e85c2da5` |
| `HarcMobileUITests`, warm retry | **No tests executed**; same CoreDevice automation-mode timeout | `3483d96d7e392e529193570c26dde849bbad3c26acc559365f1730df2b26743b` |

The zipped result bundles are retained locally under
`build/qualification/2026-08-23-Omega/`. That directory is intentionally
gitignored; the hashes above identify the exact local archives.

`HarcMobileSpikesTests` validates the physical harness rules. A passing guard
suite is not a passing codec experiment: no three-hour real-time capture cell
was run in this diagnostic.

## Physical UI timeout diagnosis

The preserved runner diagnostics narrow both physical UI failures to the iOS
automation service, after Harc and the test bundle were already healthy enough
to start:

- Xcode installed and launched the signed UI runner;
- the runner connected to `testmanagerd.remote`, initiated its control and
  session channels, and received PID authorization;
- the runner loaded `XCTAutomationSupport`, received the test configuration,
  and initialized the automation framework;
- iOS then failed to answer the request to enable automation mode for exactly
  60 seconds, so XCTest timed out before discovering or executing a test.

This is not a Harc build, signing, launch, or test-bundle initialization
failure. It also is not a physical UI pass. Recovering that device service may
require reconnecting or rebooting Omega; neither action was taken automatically
because it changes the user's active device state.

## Simulator UI diagnostic and correction

The same current tree then ran on an iPhone 17 Simulator (`iOS 26.5`). The first
complete run executed all seven UI tests: two applicable flows passed, four
declared hardware/screenshot-environment tests skipped, and the accessibility
audit found two Record-screen captions just below Apple's contrast threshold.
Both captions now use primary text contrast.

The focused accessibility retry passed, followed by a complete exact-tree run:
**three applicable tests passed, four declared environment skips, zero
failures**. The final zipped result bundle SHA-256 is
`e7c0bbd18d7a2cd7e4d27696b003e2e31d2e6c9409ec862e67ac5c40dcec4498`.
The initial failing archive is retained with SHA-256
`5951625b969197a4b6bcf80f29a7f2391f104e98420fa5793e1e02945f5fa1cd`
and the focused passing retry with SHA-256
`9e1d5b73f20a36fc70728e12285456e163d4869de3afdac07796d834ab6dd003`.
All three are local, gitignored diagnostics under
`build/qualification/2026-08-23-iPhone17-Simulator/`.

The new `scripts/qualify-harcmobile-ui.sh` wrapper makes future runs
fail-closed and reproducible: it requires an explicit destination and a clean
tree for release evidence, enforces resource limits, and retains source,
device, log, result-summary, and digest provenance together. Dirty-tree runs
must be explicitly labeled diagnostic.

The signed current-tree rerun supplied team `63TNU5M7P4`, built and installed
the app successfully, and then made the full three-attempt bounded automation
run from 2026-08-23T17:53:43Z through 17:57:36Z. All three attempts produced
the same runner-only automation-mode timeout before a Harc test method ran;
each underlying `xcodebuild` status was 65. The fail-closed wrapper selected no
attempt. Its exact dirty-source manifest fingerprint is
`b9f67a11ef3843ed6b45a144c7cde69908156cfcdce123e146e5d9fa539d3716`,
and the unzipped per-attempt result bundles and logs remain under
`build/qualification/2026-08-23-Omega-current-tree-ui-retry-fixed/`.

## Read-only ordinary-device state audit

`./scripts/audit-mobile-state.sh Omega` copied and inspected state without
mutating the phone. The snapshot found:

- four finalized local masters and four outbox records;
- three `localOnly` records and one recoverably failed background upload;
- one resumable upload attempt with no verified receipt or cleanup intent;
- no conflicts;
- the Host still retaining the matching durable staged chunk inside its valid
  generation-expiry plus seven-day recovery window.

The retained chunk is therefore expected and recoverable today. The audit also
revealed that `reapEligibleStaging()` had no production scheduler. The resident
Host runtime now invokes a fail-soft, observable maintenance scheduler after
startup, every six hours, and after wake; focused scheduler tests and all 128
`HarcHostTransportTests` pass. This closes future unattended cleanup, without
shortening the recovery window or altering the current device state.

## Open gates

- Restore CoreDevice UI automation (three signed runner startups timed out) and
  execute the corrected UI bundle on a physical phone; the Simulator result
  cannot qualify microphone, C5, or C7.
- Run the full real-time codec and C/T/P/H physical matrix on the named oldest
  eligible and current non-Pro iPhones from a clean sealed candidate.
- Qualify a real secondary Mac, direct LAN repair, encrypted relay fallback, and
  a two-network transition with visible trust/route/session state.
- Produce and verify the exact App Store archive/export, exact-build screenshots,
  TestFlight processing, privacy/export answers, and reviewer metadata.
