# Isolated untrusted preview panel

This is an internal SwiftUI view with **no production entry point**. Only the synthetic test harness constructs it. There is no model loading, automatic scan, confirmation, assignment, graph mutation or release activation.

The panel observes the selected-source lifecycle controller rather than retaining its own preview state. Source/project invalidation removes the displayed context on the next SwiftUI update. Dismiss and Escape clear the controller and request presentation dismissal; disappearance also clears it.

## Presentation contract
- Static warning: unverified suggestion; no saved connection.
- Separate project name, authored brief, partial excerpt, complete source transcript, and explicitly unverified model label.
- Full source is expanded, never hidden behind a disclosure. Long content scrolls.
- All supplied strings use literal text, not Markdown, generated titles, hyperlinks or actions.
- Headings expose accessibility heading traits. Text remains selectable. The sole action has a stable accessibility identifier, descriptive help and cancel shortcut.
- Standard semantic text styles/spacing and native appearance support; no color-only truth signal.
- Abstention is not described as proof of no relationship. Checking source fidelity is not described as checking meaning.

## Verification and limits
Focused package tests exercise static state-copy semantics, a synthetic Store/controller fixture hosted by NSHostingView in light/dark appearance, full-source preservation, dismissal and zero graph writes. The controller lifecycle suite also passes. The test harness does not invoke a model or read user data.

Layout construction alone is not interaction qualification. The opt-in window check below adds limited Escape and visual evidence; VoiceOver, physical keyboard focus/navigation, scrolling, native window dismissal, dynamic accessibility-size and live multi-process qualification remain required before any production entry point. A view update is not atomic authorization: a future confirmation still requires a fresh Store transaction against all captured identities.

Windowless AppKit cache capture and SwiftUI ImageRenderer were attempted for synthetic visual inspection. Both produced incomplete content (the latter omitted ScrollView content); neither is accepted as a visual pass, and the export experiment is not retained. These initial failures were superseded by the later successful short-fixture window captures below; broader visual qualification remains pending.

## Presentation identity correction
Each panel captures an opaque controller generation on construction. It neither displays nor dismisses a later generation. The same guard covers its button and disappearance callback. The owner must construct a fresh panel for each newly begun session; reusing an old panel deliberately shows an expired state. A deterministic regression begins a new selection, publishes its preview, delivers the old presentation's dismissal, and verifies the new source survives; current dismissal still clears it.

An additional explicit HARC_PREVIEW_WINDOW_QA=1 test path opens only a synthetic test-owned AppKit window, captures its content, dispatches Escape through the window responder chain, and closes that window. This is not a production entry point or human VoiceOver exercise.

## November 17 window check
The final opt-in run passed 10 focused test methods (8 lifecycle plus 2 panel; parameterized cases include both appearances). A test-owned AppKit window was opened in each appearance and closed by the harness. Sending an Escape key-equivalent event through NSWindow returned handled and cleared the controller preview in both cases. This is programmatic responder routing, not a human keyboard/VoiceOver test.

Visually inspected final opaque-background window-content captures at [light](evidence/preview-panel-20261117/light.png) and [dark](evidence/preview-panel-20261117/dark.png): complete short synthetic source, blocker, warning, project brief and unverified label are visible. Markdown-like URL text and asterisks remain literal. These are 640×640 synthetic content captures, not full-desktop screenshots; no private recordings or model inference. Earlier transparent captures and ImageRenderer ScrollView omissions were not accepted. Long-text scrolling, other widths and actual accessibility operation remain unqualified.

## Long-source and accessibility investigation
Opt-in command: HARC_PREVIEW_WINDOW_QA=1 HARC_PREVIEW_LONG_SOURCE_QA=1 swift test --filter UntrustedProjectPreviewPanelTests (using the SSD scratch path).

A 100-line synthetic source was resized from 640×640 to 360×480 and scrolled to the end through NSScrollView. Document height and nonzero scroll offset assertions succeeded. Inspected [narrow light](evidence/preview-panel-20261117/long-light.png) and [narrow dark](evidence/preview-panel-20261117/long-dark.png) captures show the final source correction, unverified label and persistent warning/Dismiss/footer without clipping in this fixture. Escape still cleared the preview.

**The opt-in combined QA run FAILED accessibility assertions, four failures across light/dark.** Window-root traversal returned only the shell title; direct NSHostingView traversal returned no textual accessibility descendants. Supporting standard accessibility getters on SwiftUI proxy objects did not fix this. Assertions requiring Dismiss and the final source correction remain intact in the harness. This does not distinguish a SwiftUI test-host exposure limitation from a product accessibility defect; neither accessibility nor VoiceOver is qualified. No permissions or system accessibility settings were changed. A real accessibility-client/VoiceOver investigation remains necessary before activation. Passing default package tests do not supersede this failed opt-in gate.

The visual/scrolling observations above are useful partial evidence, not a claim that the combined run passed or that all long transcripts, widths, input methods and accessibility settings work.

## Accessibility probe controls
The walker now reads accessibilityTitle as well as label/value, records role/identifier and child/navigation-order counts, and follows only actual accessibility children (not NSView subviews). This fixes a diagnostic blind spot without removing either panel assertion.

In the same test window, native NSButton/NSTextField controls expose AXButton/AXStaticText and their expected text. Both minimal SwiftUI Button/Text and the preview NSHostingView expose zero children. See [controls](evidence/preview-panel-20261117/accessibility-controls.txt) and [panel](evidence/preview-panel-20261117/accessibility-panel.txt). Native controls are probe diagnostics, not substitutes for panel assertions.

Both the test process and separate read-only AX probe already had accessibility trust. No trust prompt, settings change or force-AX flag was used. The actual AX client targeted only the synthetic test PID and failed all application reads with kAXErrorCannotComplete (-25204), including AXRole/AXChildren; see [client](evidence/preview-panel-20261117/accessibility-client.txt). This suggests a test-host/client-path problem is possible, but does not establish its cause or exonerate the view. The opt-in combined run still fails four assertions. A properly app-hosted real-client/VoiceOver run remains an unresolved activation gate.

Reproduce the additional client diagnostic by compiling Tools/PreviewAccessibilityProbe.swift to a temporary executable, then adding HARC_PREVIEW_AX_PROBE=/path/to/executable to the opt-in test command. The helper exits without prompting if existing trust is absent. It reads only the explicit synthetic test PID, with bounded tree depth/node count and a messaging timeout.
