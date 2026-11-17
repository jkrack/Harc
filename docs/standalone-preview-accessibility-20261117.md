# Standalone synthetic preview AX qualification

A separate development-only .app now hosts the same preview/controller against a synthetic temporary Store with a normal NSApplication lifecycle and run loop. Native controls and a minimal SwiftUI control window are diagnostic siblings. No model runs, production Library reads, production entry points, permission prompts, trust changes or force-accessibility flags occur.

The fixture target is absent from the default Package graph. HARC_BUILD_PREVIEW_QA=1 explicitly adds it; it is not an app-project target or shipping product. The internal panel remains internal; the debug fixture imports HarcUI testably.

## Reproduction
Run Tools/run-preview-accessibility-qa.sh with the SSD scratch path and an evidence output directory. It builds the opted-in debug fixture, creates a temporary .app, launches it independently, and runs the separate read-only AX client against only that PID. The client requires existing trust (otherwise exits without a prompt), has a 2-second per-message timeout and 20-second whole-process watchdog, and caps depth/nodes. The fixture self-terminates after 120 seconds; normal script cleanup sends TERM to only its captured PID, which is handled by NSApplication termination, allows five seconds for normal exit, then terminates only that still-running shell child if needed, and deletes only its generated bundle directory. Temporary synthetic Store data is removed on app termination.

## Observed result
On November 17, the reproducible script exited zero. All nine [assertions](evidence/standalone-preview-ax-20261117/assertions.json) passed against the [external AX tree](evidence/standalone-preview-ax-20261117/ax-tree.txt):
- application and panel Dismiss AXButton/identifier exposed;
- unverified warning, complete-source heading and final blocked-approval correction exposed;
- complete-source identifier and scroll area exposed;
- native and minimal SwiftUI diagnostic controls exposed.

Unsupported optional attribute reads are retained in the raw tree. They are not transport failures; the application and expected panel descendants were successfully traversed. The source is entirely synthetic.

## Interpretation and remaining limits
This is successful external AX content exposure under a proper app lifecycle. It resolves the question of whether this fixture can expose the required content, but does not establish why the Swift Testing process could not. The earlier four failed opt-in getter assertions, minimal-control results and CannotComplete errors remain unchanged in PR227 evidence. They are not silently rerated as passes.

No AXPress, AX scrolling action, human keyboard traversal or VoiceOver speech was performed here. Earlier native scrolling/resize and programmatic Escape checks remain separate evidence. Real app integration, actual VoiceOver/focus order, dynamic accessibility sizes, future write authorization and production activation remain gated. No feature was enabled or released.

Default package description confirmed the fixture is absent without opt-in; the 10 focused panel/lifecycle tests passed on the final default graph. One connection-interrupted test attempt had no completion evidence and was not counted; a fresh run was made only after checking no prior process remained.
