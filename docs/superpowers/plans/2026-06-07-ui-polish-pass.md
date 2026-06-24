# Harc UI Polish Pass

Date: 2026-06-07

## Scope

This pass followed the native UI rebuild direction in
`docs/superpowers/plans/2026-04-27-native-ui-rebuild.md`, but kept the work
incremental and buildable. It focused on high-frequency UI surfaces that still
felt custom after the native rebuild:

- menu bar recording panel
- local stack readiness
- transcript editor banners and transport bar
- settings warning states and destination picker
- summary card states
- sidebar section controls
- shared empty states

No audio, daemon, store, summarizer, voiceprint, or transcription behavior was
changed.

## Changes

- Added `NativeStatusCallout`, a small shared status presentation primitive for
  informational, success, warning, and danger states. This is intentionally not a
  design token system; it wraps system material, separator color, and a narrow
  status tint.
- Rebuilt `EmptyStateView` on `ContentUnavailableView` so empty states inherit
  native macOS spacing, typography, and affordances.
- Moved local stack readiness into `GroupBox`, removing a custom rounded
  background.
- Converted menu bar active capture, post-stop tray, auto-stop, stop recovery,
  recovery inbox, and note-link feedback surfaces to the shared native callout.
- Converted transcript editor save/export errors, stale timestamp hints, and
  missing-audio playback state to native callouts; the transport bar now uses
  `.bar`.
- Replaced the sidebar section header's always-visible reorder buttons with a
  small native menu, keeping the same reorder/reset actions in a less noisy
  affordance.
- Replaced the settings destination-folder custom pill with `LabeledContent` and
  native form controls.
- Converted recording settings destination and notification warnings to the
  shared callout.
- Rendered summary card containers as `GroupBox` and converted stale summary
  warnings to native callouts.
- Softened speaker suggestion chips to capsule-shaped native controls.
- Regenerated `Harc.xcodeproj` after adding the new SwiftUI source file.

## Validation

Passed:

```bash
swift build
swift test
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

Focused checks also passed during the pass:

```bash
swift test --filter LocalStackHealthTests
swift test --filter TranscriptEditorViewModelTests
swift test --filter PostStopTrayState
swift test --filter MenuBarPanelVersionTests
swift test --filter HarcPreferencesTests
swift test --filter LibraryNavigationStateTests
swift test --filter CustomerExperienceE2ETests
swift test --filter SummaryCardStateTests
swift test --filter SpeakerSuggestionEngineTests
swift test --filter SpeakerReIDServiceTests
```

## Notes

- `HarcDesign` and legacy token usages are absent from active app/test source.
  Remaining matches are historical specs and old implementation plans.
- `HarcBrand` remains the small brand layer: live recording red plus app-icon
  gradient.
- The pass deliberately avoided visual rewrites of the note editor web content
  and transcript text rendering because those surfaces have separate behavioral
  contracts.

## Follow-up

- Visually QA the main window, menu bar panel, settings, and transcript editor in
  the running app across light/dark appearances and accent colors.
- Continue shrinking custom backgrounds in `HarcWindowRootView`, especially wiki
  and review rows that still use hand-built rounded rectangles.
- Consider splitting `HarcWindowRootView` into smaller native views so future
  polish can be reviewed and tested per surface instead of in one very large
  file.
- Add screenshot or preview-based UI regression coverage once the preferred
  local visual test workflow is settled.
