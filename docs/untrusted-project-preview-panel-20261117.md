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

Layout construction is **not** real keyboard, Escape, VoiceOver, scrolling, focus, window-dismissal, dynamic accessibility-size or live multi-process qualification. Those remain required before any production entry point. A view update is not atomic authorization: a future confirmation still requires a fresh Store transaction against all captured identities.

Windowless AppKit cache capture and SwiftUI ImageRenderer were attempted for synthetic visual inspection. Both produced incomplete content (the latter omitted ScrollView content); neither is accepted as a visual pass, and the export experiment is not retained. Actual window-hosted visual qualification remains pending.
