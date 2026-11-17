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

Windowless AppKit cache capture and SwiftUI ImageRenderer were attempted for synthetic visual inspection. Both produced incomplete content (the latter omitted ScrollView content); neither is accepted as a visual pass, and the export experiment is not retained. Actual window-hosted visual qualification remains pending.

## Presentation identity correction
Each panel captures an opaque controller generation on construction. It neither displays nor dismisses a later generation. The same guard covers its button and disappearance callback. The owner must construct a fresh panel for each newly begun session; reusing an old panel deliberately shows an expired state. A deterministic regression begins a new selection, publishes its preview, delivers the old presentation's dismissal, and verifies the new source survives; current dismissal still clears it.

An additional explicit HARC_PREVIEW_WINDOW_QA=1 test path opens only a synthetic test-owned AppKit window, captures its content, dispatches Escape through the window responder chain, and closes that window. This is not a production entry point or human VoiceOver exercise.

## November 17 window check
The final opt-in run passed 10 focused test methods (8 lifecycle plus 2 panel; parameterized cases include both appearances). A test-owned AppKit window was opened in each appearance and closed by the harness. Sending an Escape key-equivalent event through NSWindow returned handled and cleared the controller preview in both cases. This is programmatic responder routing, not a human keyboard/VoiceOver test.

Visually inspected final opaque-background window-content captures at [light](evidence/preview-panel-20261117/light.png) and [dark](evidence/preview-panel-20261117/dark.png): complete short synthetic source, blocker, warning, project brief and unverified label are visible. Markdown-like URL text and asterisks remain literal. These are 640×640 synthetic content captures, not full-desktop screenshots; no private recordings or model inference. Earlier transparent captures and ImageRenderer ScrollView omissions were not accepted. Long-text scrolling, other widths and actual accessibility operation remain unqualified.
