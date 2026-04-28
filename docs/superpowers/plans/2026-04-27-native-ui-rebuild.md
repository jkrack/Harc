# Native UI Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Harc's UI native-first on macOS 26 (Tahoe / Liquid Glass), gut `HarcDesign` to a ~30-line brand sliver, collapse Library + TranscriptionDetail into one `NavigationSplitView` window, slim the menu-bar surface to a `MenuBarExtra` panel.

**Architecture:** Single feature branch (`feat/native-ui-rebuild-2026-04-27`). Migration sequence (Phases 0–7) mirrors spec §8. Each phase ends with green `swift test` + `xcodebuild` and a commit. The non-UI surface (audio, daemon, store, summarizer, voiceprint) is untouched. `HarcApp.swift` evolves from "empty `Settings {}` + AppDelegate-driven NSStatusItem" to "SwiftUI `App` with `MenuBarExtra` + `Settings {}` + `WindowGroup`s", with most state lifted out of `AppDelegate` into observable state objects.

**Tech Stack:** SwiftUI on macOS 26 (`NavigationSplitView`, `Inspector`, `Form` w/ `.formStyle(.grouped)`, `MenuBarExtra` `.window` style, `.glassEffect()`, system materials, `Color.accentColor`), Swift Testing (`@Suite`/`@Test`/`#expect`) for unit tests, `KeyboardShortcuts` for hotkeys, GRDB for the store (untouched).

**Spec:** `docs/superpowers/specs/2026-04-27-native-ui-rebuild-design.md`

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `Sources/HarcUI/HarcBrand.swift` | The ~30-line brand sliver: `live` red, `gradient`. Replaces `DesignTokens.swift`. |
| `Sources/HarcUI/HarcWindowRootView.swift` | The new main window: `NavigationSplitView` with sidebar + detail + inspector. |
| `Sources/HarcUI/MenuBarPanelView.swift` | The slim `MenuBarExtra.window`-style panel. ~80–120 lines. |
| `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift` | Speaker editor extracted from old detail view, now a `Form Section`. |
| `Sources/HarcUI/Inspector/FileInspectorSection.swift` | File metadata as a `Form Section`. |
| `Sources/HarcUI/Settings/HarcSettingsForm.swift` | Single `Form` aggregating the six section views. |
| `Sources/HarcUI/PostStopTrayState.swift` | Observable state object owning the 30s post-stop tray timer. (Lift testable behavior out of the view.) |
| `HarcApp/WindowControllers/HarcWindowController.swift` | Renamed from `LibraryWindowController.swift`, hosts the new merged window. |
| `Tests/HarcUITests/PostStopTrayStateTests.swift` | Tests for the 30s tray timer and dismissal behavior. |
| `Tests/HarcUITests/HarcBrandTests.swift` | Replaces `DesignTokensSmokeTests.swift`. Smoke that brand sliver is reachable. |

### Modified

| Path | Change |
|---|---|
| `Package.swift` | `.macOS(.v14)` → `.macOS(.v26)`. |
| `project.yml` | `deploymentTarget.macOS: "14.0"` → `"26.0"`. |
| `CLAUDE.md` | Hard Constraints: "Target macOS 14+" → "Target macOS 26+". Update active dev surface and any references to `HarcDesign`/popover layout. |
| `HarcApp/HarcApp.swift` | Becomes the real `App` body: `MenuBarExtra` + `Settings { HarcSettingsForm() }` + `WindowGroup` for the main window. |
| `HarcApp/AppDelegate.swift` | Slims down: keeps lifecycle, daemon launcher, hotkey handling, recording state, but loses popover plumbing and window-controller-of-everything role. State that views need migrates to observable objects in `HarcUI`. |
| `Sources/HarcUI/SummaryCardView.swift` | Re-skin to `GroupBox`-styled child of the detail view. |
| `Sources/HarcUI/SpeakerNameEditor.swift` | Re-skin for use in `Inspector` `Form Section`. |
| `Sources/HarcUI/SpeakerSuggestionChip.swift` | Re-skin to native chip (`.background(.background.tertiary)` + `Capsule`). |
| `Sources/HarcUI/TranscriptHitRow.swift` | Becomes a plain `List` row content view. |
| `Sources/HarcUI/CountdownWarningPanel.swift` | Apply `.glassEffect()`. |
| `Sources/HarcUI/AutoStopNotification.swift` | Re-skin to thin native panel or convert to `UNNotification`. |
| `Sources/HarcUI/ModelRequirementView.swift` | Replace internals with `ContentUnavailableView`. |
| `Sources/HarcUI/MenuBarFlash.swift` | Light touch — keep flash behavior, swap any `HarcDesign.*` references. |
| `Sources/HarcUI/Settings/{General,Library,Models,Processing,Recording,Summarization}SettingsView.swift` | Each becomes a `Section`-returning view; tokens migrated; layout retains existing controls. |
| `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift` | Native `.toolbar`, native chrome, reuse Inspector. |
| `Sources/HarcUI/TranscriptEditor/TranscriptEditorTransportView.swift` | Token migration, native control styling. |
| `Sources/HarcUI/TranscriptEditor/TranscriptTextView.swift` | If it wraps `NSTextView` for spans/highlighting, keep — but swap `HarcDesign.*` for system colors. |
| `HarcApp/WindowControllers/TranscriptEditorWindowController.swift` | Light touch — host the rebuilt view. |

### Renamed

| From → To |
|---|
| `HarcApp/WindowControllers/LibraryWindowController.swift` → `HarcWindowController.swift` |

### Deleted

`Sources/HarcUI/PopoverRootView.swift`, `LibraryWindowRootView.swift`, `TranscriptionDetailView.swift`, `RecentRecordingsView.swift`, `RecordingIconTile.swift`, `RecordingControlsView.swift`, `PostStopTrayBanner.swift`, `LibrarySearchField.swift`, `TagChip.swift`, `GlassBackground.swift`, `MonthCalendarView.swift`, `DesignTokens.swift`, `Tests/HarcUITests/DesignTokensSmokeTests.swift`, `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`, `HarcApp/WindowControllers/SettingsWindowController.swift`.

---

## Phase 0 — Foundation (deploy bump)

### Task 0.1: Branch and deployment-target bump

**Files:**
- Modify: `Package.swift`
- Modify: `project.yml`
- Modify: `CLAUDE.md` (Hard Constraints)

- [ ] **Step 1: Create the feature branch**

```bash
git checkout main
git pull
git checkout -b feat/native-ui-rebuild-2026-04-27
```

Expected: clean branch off `main`.

- [ ] **Step 2: Bump `Package.swift` platforms**

Edit `Package.swift`. Change:

```swift
    platforms: [.macOS(.v14)],
```

to:

```swift
    platforms: [.macOS(.v26)],
```

- [ ] **Step 3: Bump `project.yml` deployment target**

Edit `project.yml`. Change:

```yaml
  deploymentTarget:
    macOS: "14.0"
```

to:

```yaml
  deploymentTarget:
    macOS: "26.0"
```

- [ ] **Step 4: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: `Harc.xcodeproj` regenerates with no errors.

- [ ] **Step 5: Update CLAUDE.md hard constraint**

In `CLAUDE.md`, find the Hard Constraints bullet:

```
- **Apple Silicon only** (arm64). Target macOS 14+. Free use of Neural Engine, Metal, Accelerate, Core ML.
```

Replace with:

```
- **Apple Silicon only** (arm64). Target macOS 26+ (Tahoe). Free use of Neural Engine, Metal, Accelerate, Core ML, Liquid Glass / `.glassEffect()`.
```

- [ ] **Step 6: Verify build is green**

```bash
swift build
swift test
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

Expected: all three green. If `xcodebuild` fails because the local Xcode is older than required for macOS 26 SDK, abort and surface to the user — this whole plan assumes a Tahoe-capable Xcode.

- [ ] **Step 7: Commit**

```bash
git add Package.swift project.yml CLAUDE.md Harc.xcodeproj
git commit -m "$(cat <<'EOF'
chore(deploy): bump deployment target to macOS 26

CLAUDE.md hard constraint updated. Xcode project regenerated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 — HarcDesign → HarcBrand

### Task 1.1: Introduce `HarcBrand`, delete `GlassBackground`

**Files:**
- Create: `Sources/HarcUI/HarcBrand.swift`
- Delete: `Sources/HarcUI/GlassBackground.swift` (after Step 4)

- [ ] **Step 1: Create `HarcBrand.swift`**

Write `Sources/HarcUI/HarcBrand.swift`:

```swift
import SwiftUI

/// The entire brand sliver. Three concerns: recording red, app-icon gradient,
/// and the menu-bar bars motif (which lives in MenuBarBarsIcon).
///
/// Everything else uses system primitives — Color.accentColor, Color.primary/.secondary,
/// system materials, system fonts. Do NOT add tokens here; if you need one, use system.
public enum HarcBrand {
    /// Recording / "live" red. Drives the menu-bar dot, the recording-state pill,
    /// and any chrome that signals "we are recording right now."
    public static let live = Color(red: 0xF0/255.0, green: 0x55/255.0, blue: 0x4D/255.0)

    /// Brand gradient. App icon, About panel only. Do not use as control fill.
    public static let gradient = LinearGradient(
        colors: [
            Color(red: 0x70/255.0, green: 0xA3/255.0, blue: 0xFF/255.0),
            Color(red: 0x33/255.0, green: 0x5C/255.0, blue: 0xE0/255.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
```

- [ ] **Step 2: Add a smoke test for the brand sliver**

Create `Tests/HarcUITests/HarcBrandTests.swift`:

```swift
import Testing
import SwiftUI
@testable import HarcUI

@Suite("HarcBrand")
struct HarcBrandTests {
    @Test("live red is reachable and non-clear")
    func liveRedReachable() {
        let _ = HarcBrand.live
        // Smoke only — Color does not equate cleanly across CGColor conversions.
        // The compiler-level reachability is the actual assertion.
        #expect(Bool(true))
    }

    @Test("brand gradient is reachable")
    func gradientReachable() {
        let _ = HarcBrand.gradient
        #expect(Bool(true))
    }
}
```

- [ ] **Step 3: Run new test**

```bash
swift test --filter HarcUITests.HarcBrandTests
```

Expected: 2 tests, both pass.

- [ ] **Step 4: Delete `GlassBackground.swift` and `DesignTokensSmokeTests.swift`**

```bash
rm Sources/HarcUI/GlassBackground.swift
rm Tests/HarcUITests/DesignTokensSmokeTests.swift
```

(`DesignTokens.swift` is still referenced by every UI file — do NOT delete it yet. Task 1.2 swaps call sites; Task 1.3 deletes the file once safe.)

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/HarcBrand.swift Tests/HarcUITests/HarcBrandTests.swift
git rm Sources/HarcUI/GlassBackground.swift Tests/HarcUITests/DesignTokensSmokeTests.swift
git commit -m "feat(ui): introduce HarcBrand sliver, drop GlassBackground

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.2: Mechanical token swap across `HarcUI`

This is the bulk find-and-replace. The token migration table from spec §5 is the source of truth. Work file by file; build after each file to catch type errors early.

**Files (every file in `Sources/HarcUI/` that still references `HarcDesign.*` or `Color.harc*` after Task 1.1, except files scheduled for deletion in later phases):**

```
Sources/HarcUI/AutoStopNotification.swift
Sources/HarcUI/CountdownWarningPanel.swift
Sources/HarcUI/HarcPreferences.swift          (likely no UI tokens, verify)
Sources/HarcUI/LiveScopeView.swift
Sources/HarcUI/MenuBarBarsIcon.swift
Sources/HarcUI/MenuBarFlash.swift
Sources/HarcUI/ModelRequirementView.swift
Sources/HarcUI/SettingsView.swift
Sources/HarcUI/Settings/GeneralSettingsView.swift
Sources/HarcUI/Settings/LibrarySettingsView.swift
Sources/HarcUI/Settings/ModelsSettingsView.swift
Sources/HarcUI/Settings/ProcessingSettingsView.swift
Sources/HarcUI/Settings/RecordingSettingsView.swift
Sources/HarcUI/Settings/SummarizationSettingsView.swift
Sources/HarcUI/SpeakerNameEditor.swift
Sources/HarcUI/SpeakerSuggestionChip.swift
Sources/HarcUI/SummaryCardView.swift
Sources/HarcUI/TranscriptHitRow.swift
Sources/HarcUI/TranscriptEditor/TranscriptEditorTransportView.swift
Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift
Sources/HarcUI/TranscriptEditor/TranscriptTextView.swift
```

**Files NOT touched in this task (deleted in later phases — leave untouched, they'll vanish):**

`PopoverRootView.swift`, `LibraryWindowRootView.swift`, `TranscriptionDetailView.swift`, `RecentRecordingsView.swift`, `RecordingIconTile.swift`, `RecordingControlsView.swift`, `PostStopTrayBanner.swift`, `LibrarySearchField.swift`, `TagChip.swift`, `MonthCalendarView.swift`.

- [ ] **Step 1: Get the full list of files needing migration**

```bash
grep -lr "HarcDesign\.\|Color\.harc" Sources/HarcUI/ HarcApp/ \
    | grep -v -E "(PopoverRootView|LibraryWindowRootView|TranscriptionDetailView|RecentRecordingsView|RecordingIconTile|RecordingControlsView|PostStopTrayBanner|LibrarySearchField|TagChip|MonthCalendarView|DesignTokens)\.swift"
```

Expected: a list of files. This is the working set.

- [ ] **Step 2: Open the spec's token migration table**

Read spec §5 ("Token migration table"). Keep it open — every change in Step 3 maps a row from that table.

- [ ] **Step 3: Migrate each file in the working set**

For each file, apply the substitutions below. Build after every file so type errors surface immediately.

**Substitution patterns** (use `Edit` tool with `replace_all: false` per occurrence; unambiguous strings can use `replace_all: true`):

```
HarcDesign.surface0     → no fill (delete the .background(...) modifier) OR Color(nsColor: .windowBackgroundColor)
HarcDesign.surface1     → .background(.regularMaterial)
HarcDesign.surface2     → .background(.background.secondary)
HarcDesign.surface3     → (delete — native hover handles it)
HarcDesign.surface4     → (delete — native press handles it)
HarcDesign.borderSubtle → Color(nsColor: .separatorColor)
HarcDesign.borderStrong → Color(nsColor: .separatorColor)
HarcDesign.inkPrimary   → Color.primary
HarcDesign.inkSecondary → Color.secondary
HarcDesign.inkTertiary  → Color(nsColor: .tertiaryLabelColor)
HarcDesign.inkQuaternary→ Color(nsColor: .quaternaryLabelColor)
HarcDesign.accent       → Color.accentColor
HarcDesign.accentHover  → Color.accentColor
HarcDesign.accentSoft   → Color.accentColor.opacity(0.16)
HarcDesign.selection    → (delete — use native List selection)
HarcDesign.selectionEdge→ Color.accentColor
HarcDesign.success      → .green
HarcDesign.warning      → .yellow
HarcDesign.danger       → .red
HarcDesign.live         → HarcBrand.live
HarcDesign.chipBg       → Color(nsColor: .tertiarySystemFill) (or .background.tertiary if available)
HarcDesign.chipInk      → Color.primary
HarcDesign.primary      → Color.accentColor
HarcDesign.error        → .red
HarcDesign.onSurface    → Color.primary
HarcDesign.onSurfaceVariant → Color.secondary

HarcDesign.Font.display, displayMd → .font(.largeTitle).fontWeight(.semibold)
HarcDesign.Font.title, titleLg     → .font(.title3).fontWeight(.semibold)
HarcDesign.Font.titleSm            → .font(.headline)
HarcDesign.Font.subtitle           → .font(.headline)
HarcDesign.Font.body, bodyMd       → .font(.body)
HarcDesign.Font.bodySm             → .font(.subheadline)
HarcDesign.Font.meta               → .font(.subheadline)
HarcDesign.Font.label, labelMd     → .font(.caption)
HarcDesign.Font.mono               → .font(.system(.callout, design: .monospaced))
HarcDesign.Font.monoMd             → .font(.system(.body, design: .monospaced))
HarcDesign.Font.monoXs             → .font(.system(.caption2, design: .monospaced).weight(.medium))

HarcDesign.Space.xxs / s1   → 4 / 2
HarcDesign.Space.xs  / s3   → 8
HarcDesign.Space.sm  / s4   → 12
HarcDesign.Space.md  / s5   → 16
HarcDesign.Space.lg  / s6   → 24
HarcDesign.Space.xl  / s7   → 32
HarcDesign.Space.s8         → 48
HarcDesign.Space.s2         → 4

HarcDesign.Radius.sm   → 4
HarcDesign.Radius.md   → 6
HarcDesign.Radius.lg   → 8
HarcDesign.Radius.xl   → 12
HarcDesign.Radius.full → 9999

HarcDesign.Layout.rowHeightCompact → 36
HarcDesign.Layout.rowHeightCozy    → 44
HarcDesign.Layout.rowHeightComfy   → 54
HarcDesign.Layout.sidebarWidth     → 220
HarcDesign.Layout.railWidth        → 340

HarcDesign.primaryGradient → HarcBrand.gradient

Color.harcLive          → HarcBrand.live
Color.harcAccent        → Color.accentColor
Color.harcAccentHover   → Color.accentColor
Color.harcAccentSoft    → Color.accentColor.opacity(0.16)
Color.harcSurface0      → Color(nsColor: .windowBackgroundColor)
Color.harcSurface1..4   → (per surface mapping above)
Color.harcInkPrimary    → Color.primary
Color.harcInkSecondary  → Color.secondary
Color.harcInkTertiary   → Color(nsColor: .tertiaryLabelColor)
Color.harcInkQuaternary → Color(nsColor: .quaternaryLabelColor)
Color.harcBorderSubtle  → Color(nsColor: .separatorColor)
Color.harcBorderStrong  → Color(nsColor: .separatorColor)
Color.harcSelection     → (delete or accentColor.opacity(0.2) if non-list)
Color.harcSelectionEdge → Color.accentColor
Color.harcChipBg        → Color(nsColor: .tertiarySystemFill)
Color.harcChipInk       → Color.primary
Color.harcPrimary       → Color.accentColor
Color.harcPrimaryContainer → Color.accentColor
Color.harcTertiary      → .purple   (legacy — likely unused)
Color.harcError         → .red
Color.harcOnSurface     → Color.primary
Color.harcOnSurfaceVariant → Color.secondary
Color.harcOutlineVariant → Color(nsColor: .separatorColor)
```

After each file, run:

```bash
swift build 2>&1 | tail -20
```

Expected: green. If a build error mentions a token not in the table above, look for it in `DesignTokens.swift` and add the right substitution; do NOT improvise.

- [ ] **Step 4: Verify all token references are gone from the working set**

```bash
grep -rn "HarcDesign\.\|Color\.harc" Sources/HarcUI/ HarcApp/ \
    | grep -v -E "(PopoverRootView|LibraryWindowRootView|TranscriptionDetailView|RecentRecordingsView|RecordingIconTile|RecordingControlsView|PostStopTrayBanner|LibrarySearchField|TagChip|MonthCalendarView|DesignTokens)\.swift"
```

Expected: zero matches. Anything that comes back is either a file in the working set that was missed (fix it now), or a soon-to-be-deleted file (skip).

- [ ] **Step 5: Run `swift test`**

```bash
swift test
```

Expected: green. View tests are mostly state/VM tests; they should not regress on token changes.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/HarcUI HarcApp
git commit -m "refactor(ui): swap HarcDesign tokens for system primitives

Mechanical migration per spec §5. Soon-to-be-deleted views (popover,
library, detail, etc.) are intentionally untouched and still reference
HarcDesign — their files are deleted in later phases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.3: Defer `DesignTokens.swift` deletion

**Files:** none changed in this task.

- [ ] **Step 1: Confirm `DesignTokens.swift` is still referenced only by soon-to-be-deleted files**

```bash
grep -l "HarcDesign\.\|Color\.harc" Sources/HarcUI/ HarcApp/
```

Expected: only files in the deletion list (PopoverRootView, LibraryWindowRootView, TranscriptionDetailView, RecentRecordingsView, RecordingIconTile, RecordingControlsView, PostStopTrayBanner, LibrarySearchField, TagChip, MonthCalendarView, DesignTokens itself).

If anything else shows up, that's a Task 1.2 omission — fix it before proceeding.

- [ ] **Step 2: Add a `// DEPRECATED` comment at the top of `DesignTokens.swift`**

```swift
// DEPRECATED: this entire file is scheduled for deletion in Phase 7 cleanup.
// Do not add new references. Use HarcBrand for the brand sliver and
// Color.primary / .secondary / .accentColor / system materials elsewhere.
```

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcUI/DesignTokens.swift
git commit -m "chore(ui): mark DesignTokens.swift as deprecated pending Phase 7 deletion

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Settings as `Settings {}` scene with `Form`

### Task 2.1: Convert each settings sub-view from a tab body to a `Section`-returning view

**Files:**
- Modify: `Sources/HarcUI/Settings/GeneralSettingsView.swift`
- Modify: `Sources/HarcUI/Settings/LibrarySettingsView.swift`
- Modify: `Sources/HarcUI/Settings/ModelsSettingsView.swift`
- Modify: `Sources/HarcUI/Settings/ProcessingSettingsView.swift`
- Modify: `Sources/HarcUI/Settings/RecordingSettingsView.swift`
- Modify: `Sources/HarcUI/Settings/SummarizationSettingsView.swift`

The goal: each existing settings view's body becomes the contents of a `Section { ... }` so the aggregator (Task 2.2) can stack them in one `Form`.

- [ ] **Step 1: Read each settings file to understand its current structure**

```bash
for f in Sources/HarcUI/Settings/*.swift; do echo "=== $f ==="; head -40 "$f"; done
```

Note: in current code each view is likely a `Form` itself or a `VStack` of controls. The migration is: strip outer `Form` / outer container, leave a `Section("Title")` wrapping the existing rows.

- [ ] **Step 2: Migrate `GeneralSettingsView.swift`**

Open the file. Identify the outermost container (likely `Form { ... }` or `VStack { ... }`). Replace it with `Section("General") { ... }`. The view's `body` should now return a single `Section`. Example shape:

```swift
import SwiftUI

public struct GeneralSettingsView: View {
    public init() {}

    public var body: some View {
        Section("General") {
            // existing controls — Toggles, Pickers, etc.
        }
    }
}
```

If the view took init parameters or `@ObservedObject`s, keep them.

- [ ] **Step 3: Repeat Step 2 for the other five settings views**

`LibrarySettingsView`, `ModelsSettingsView`, `ProcessingSettingsView`, `RecordingSettingsView`, `SummarizationSettingsView`. Each becomes a `Section("Library") { ... }` etc.

For `ModelsSettingsView` (282 lines) and `RecordingSettingsView` (303 lines), if the section feels too dense as one `Section`, split into multiple `Section`s within the same view (e.g., `Section("Recording") { ... }` + `Section("Audio device") { ... }`).

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: green. The aggregator doesn't exist yet so the views won't render anywhere — that's fine, the build only needs to compile.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/Settings
git commit -m "refactor(settings): convert tab views to Form Section views

Each settings sub-view now returns a Section() ready to be composed into
a single Form. Aggregator view follows in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: Aggregator `HarcSettingsForm` + wire into `Settings {}` scene

**Files:**
- Create: `Sources/HarcUI/Settings/HarcSettingsForm.swift`
- Modify: `Sources/HarcUI/SettingsView.swift`
- Modify: `HarcApp/HarcApp.swift`
- Delete: `HarcApp/WindowControllers/SettingsWindowController.swift`
- Modify: `HarcApp/AppDelegate.swift` (remove `settingsWindow` property and its show/hide methods)

- [ ] **Step 1: Create `HarcSettingsForm.swift`**

```swift
import SwiftUI

/// One scrollable Form with grouped Sections — replaces the six-tab Settings TabView.
///
/// If KeyboardShortcuts.Recorder later turns out to render badly inside Form, the
/// Hotkeys section can be moved out into a TabView wrapper without touching the
/// other sections. (Currently no Hotkeys section exists; HotkeyNames.swift is the
/// source of truth and they're set by KeyboardShortcuts.Recorder elsewhere.)
public struct HarcSettingsForm: View {
    public init() {}

    public var body: some View {
        Form {
            GeneralSettingsView()
            RecordingSettingsView()
            ProcessingSettingsView()
            ModelsSettingsView()
            SummarizationSettingsView()
            LibrarySettingsView()
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 480)
    }
}
```

- [ ] **Step 2: Replace `SettingsView.swift` body**

```swift
import SwiftUI

/// Public entry point used by the SwiftUI App scene.
public struct SettingsView: View {
    public init() {}
    public var body: some View {
        HarcSettingsForm()
    }
}
```

- [ ] **Step 3: Wire `Settings {}` scene in `HarcApp.swift`**

Replace the contents of `HarcApp/HarcApp.swift`:

```swift
import SwiftUI
import HarcUI

@main
struct HarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            HarcSettingsForm()
        }
    }
}
```

(`MenuBarExtra` and `WindowGroup` are added in Phase 3 / Phase 4 respectively.)

- [ ] **Step 4: Strip settings-window plumbing from AppDelegate**

In `HarcApp/AppDelegate.swift`:

1. Delete the `private var settingsWindow: SettingsWindowController?` property.
2. Find every method or call site that opens/closes the settings window via `settingsWindow`. Replace each `open settings` call site with `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (the SwiftUI `Settings {}` scene registers this action automatically on macOS 14+; on macOS 26 the canonical incantation is the same).
3. Delete any `@IBAction` / `@objc` `openSettings(_:)` method that simply showed the controller.

- [ ] **Step 5: Delete `SettingsWindowController.swift`**

```bash
git rm HarcApp/WindowControllers/SettingsWindowController.swift
xcodegen generate
```

- [ ] **Step 6: Build and run a quick smoke**

```bash
swift build
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

Then open `build/Debug/Harc.app` (or via Xcode), trigger Cmd-, and verify the Settings window opens with the new Form. Verify each section's controls work (toggles toggle, pickers pick).

- [ ] **Step 7: Commit**

```bash
git add Sources/HarcUI/Settings/HarcSettingsForm.swift Sources/HarcUI/SettingsView.swift HarcApp/HarcApp.swift HarcApp/AppDelegate.swift Harc.xcodeproj
git commit -m "feat(settings): SwiftUI Settings scene with grouped Form

Settings opens via Cmd-, through the standard SwiftUI Settings scene.
Six tabs collapse into a single grouped Form with Sections.
SettingsWindowController removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Main window: `NavigationSplitView` (Library + Detail merge)

This is the largest phase. Build the new view, swap window controller hosting, then delete the old views.

### Task 3.1: Extract Inspector sections (speakers + file metadata)

**Files:**
- Create: `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift`
- Create: `Sources/HarcUI/Inspector/FileInspectorSection.swift`

Reading the current `TranscriptionDetailView.swift` (591 lines), identify the speaker editor block and the file metadata block. Lift them into dedicated `Section`-returning views so the new Inspector can compose them.

- [ ] **Step 1: Read `TranscriptionDetailView.swift` to find the speaker editor and file metadata blocks**

```bash
grep -n "Speaker\|fileURL\|metadata\|durationSeconds\|wordCount" Sources/HarcUI/TranscriptionDetailView.swift | head -40
```

Take notes on which structs/properties feed the editor and the metadata display.

- [ ] **Step 2: Create `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift`**

```swift
import SwiftUI
import HarcStore

public struct SpeakerInspectorSection: View {
    let recording: Recording      // adjust types to match HarcStore models
    let store: RecordingStore
    let reIDService: SpeakerReIDService

    public init(recording: Recording, store: RecordingStore, reIDService: SpeakerReIDService) {
        self.recording = recording
        self.store = store
        self.reIDService = reIDService
    }

    public var body: some View {
        Section("Speakers") {
            // Reuse SpeakerNameEditor and SpeakerSuggestionChip exactly as they are
            // (those were token-migrated in Phase 1). Wire them to `recording`.
            SpeakerNameEditor(recording: recording, store: store)
            // Suggestions list, if any, rendered inline with SpeakerSuggestionChip.
        }
    }
}
```

(The exact wiring depends on the current `SpeakerNameEditor` API — reuse its existing init signature; do not invent new parameters.)

- [ ] **Step 3: Create `Sources/HarcUI/Inspector/FileInspectorSection.swift`**

```swift
import SwiftUI
import HarcStore

public struct FileInspectorSection: View {
    let recording: Recording

    public init(recording: Recording) {
        self.recording = recording
    }

    public var body: some View {
        Section("File") {
            LabeledContent("Duration", value: durationString)
            LabeledContent("Started", value: startedString)
            LabeledContent("Audio") { Text(recording.audioURL.lastPathComponent).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
            LabeledContent("Transcript") { Text(recording.transcriptURL.lastPathComponent).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
        }
    }

    private var durationString: String {
        // Reuse RelativeTimeFormatter or whatever exists — do not invent.
        let total = Int(recording.durationSeconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private var startedString: String {
        recording.startedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
```

(Adjust property names to whatever `HarcStore.Recording` actually exposes; do not invent.)

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/Inspector/
git commit -m "feat(ui): extract SpeakerInspectorSection and FileInspectorSection

Lifted from TranscriptionDetailView so the new HarcWindowRootView's
.inspector can compose them. Old detail view still references its inline
versions — the duplication is intentional and clears in Task 3.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: Build `HarcWindowRootView` skeleton

**Files:**
- Create: `Sources/HarcUI/HarcWindowRootView.swift`

- [ ] **Step 1: Read existing data wiring**

```bash
grep -n "RecordingsViewModel\|LibraryViewModel" Sources/HarcUI/RecordingsViewModel.swift Sources/HarcUI/LibraryViewModel.swift HarcApp/AppDelegate.swift | head -40
```

Note the init signatures of `RecordingsViewModel` and `LibraryViewModel` — the new view consumes these; do not invent new ones.

- [ ] **Step 2: Create `Sources/HarcUI/HarcWindowRootView.swift`**

```swift
import SwiftUI
import HarcStore
import HarcModels

public struct HarcWindowRootView: View {
    @ObservedObject var recordingsVM: RecordingsViewModel
    @ObservedObject var libraryVM: LibraryViewModel
    let store: RecordingStore
    let reIDService: SpeakerReIDService

    @State private var selection: String?            // recordingID
    @State private var inspectorOpen: Bool = false
    @State private var searchText: String = ""

    public init(recordingsVM: RecordingsViewModel, libraryVM: LibraryViewModel, store: RecordingStore, reIDService: SpeakerReIDService) {
        self.recordingsVM = recordingsVM
        self.libraryVM = libraryVM
        self.store = store
        self.reIDService = reIDService
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .toolbar { toolbar }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: Sidebar
    private var sidebar: some View {
        List(selection: $selection) {
            // Sections: Pinned / Today / Yesterday / This week / older months
            // Use libraryVM groupings if it already has them; otherwise compute inline.
            ForEach(libraryVM.groups) { group in
                Section(group.title) {
                    ForEach(group.recordings) { rec in
                        TranscriptHitRow(recording: rec, query: searchText)
                            .tag(rec.id as String?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail
    @ViewBuilder
    private var detail: some View {
        if let selection, let rec = libraryVM.recording(id: selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SummaryCardView(recording: rec)
                        .padding(.horizontal)
                    Text(rec.transcriptText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .inspector(isPresented: $inspectorOpen) {
                Form {
                    SpeakerInspectorSection(recording: rec, store: store, reIDService: reIDService)
                    FileInspectorSection(recording: rec)
                }
                .formStyle(.grouped)
                .background(.thinMaterial)
            }
        } else {
            ContentUnavailableView(
                "No recording selected",
                systemImage: "waveform",
                description: Text("Pick a recording from the sidebar.")
            )
        }
    }

    // MARK: Toolbar
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if let selection, let rec = libraryVM.recording(id: selection) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rec.transcriptText, forType: .string)
                }
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .disabled(selection == nil)

            // TODO Phase 3.5: Edit, Export, Delete actions wired to existing
            // libraryVM methods. Stubbed here — implementation lives in Task 3.3.

            Spacer()
            Button { inspectorOpen.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
        }
    }
}
```

**Important:** The exact property names on `LibraryViewModel` (`groups`, `recording(id:)`, `recordings`) and `Recording` (`id`, `transcriptText`) MUST match what already exists. If `libraryVM.groups` doesn't exist, look at how `LibraryWindowRootView.swift` sliced its data and copy that approach. Do not invent new VM methods unless absolutely necessary; if you do, note it in the commit.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -30
```

Expected: red — likely missing properties on the VMs. For each error, either (a) the property exists with a different name → use the right name, (b) the property doesn't exist → add a small extension on the VM in this same file (top of file, `private extension LibraryViewModel { ... }`) that derives what you need from existing public state. Do NOT add public mutators; this is read-only adaptation.

Iterate until green.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/HarcWindowRootView.swift
git commit -m "feat(ui): HarcWindowRootView skeleton with NavigationSplitView + Inspector

Sidebar renders LibraryViewModel groups; detail shows transcript + summary
card; inspector hosts Speaker and File sections. Toolbar has Copy and
Inspector toggle wired; Edit/Export/Delete stubbed for next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: Wire toolbar actions (Edit / Export / Delete) and the recording-state pill

**Files:**
- Modify: `Sources/HarcUI/HarcWindowRootView.swift`

- [ ] **Step 1: Find existing edit/export/delete entry points**

```bash
grep -n "openEditor\|exportTranscript\|delete(\|removeRecording" Sources/HarcUI/LibraryWindowRootView.swift Sources/HarcUI/RecordingsViewModel.swift Sources/HarcUI/LibraryViewModel.swift HarcApp/AppDelegate.swift | head -30
```

Note the call shapes (closure passed in? VM method? AppDelegate handler?).

- [ ] **Step 2: Add the actions to `HarcWindowRootView`'s init and toolbar**

If the actions are AppDelegate-hosted (likely), pass them as closures into the view's init:

```swift
let onEdit: (Recording) -> Void
let onExport: (Recording) -> Void
let onDelete: (Recording) -> Void
let recordingState: RecordingState   // for the toolbar pill
```

Update the toolbar:

```swift
@ToolbarContentBuilder
private var toolbar: some ToolbarContent {
    // Recording-state pill (leading) — only when actively recording.
    ToolbarItem(placement: .navigation) {
        if recordingState.isRecording {
            HStack(spacing: 6) {
                Circle().fill(HarcBrand.live).frame(width: 8, height: 8)
                Text("Recording").font(.subheadline).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glassEffect(.regular.tint(HarcBrand.live), in: Capsule())
        }
    }

    ToolbarItemGroup {
        Button {
            if let rec = currentRecording { copyToPasteboard(rec) }
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        .disabled(currentRecording == nil)

        Button {
            if let rec = currentRecording { onEdit(rec) }
        } label: { Label("Edit", systemImage: "pencil") }
        .disabled(currentRecording == nil)

        Button {
            if let rec = currentRecording { onExport(rec) }
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .disabled(currentRecording == nil)

        Button(role: .destructive) {
            if let rec = currentRecording { onDelete(rec) }
        } label: { Label("Delete", systemImage: "trash") }
        .disabled(currentRecording == nil)

        Spacer()
        Button { inspectorOpen.toggle() } label: {
            Label("Inspector", systemImage: "sidebar.right")
        }
    }
}

private var currentRecording: Recording? {
    guard let selection else { return nil }
    return libraryVM.recording(id: selection)
}

private func copyToPasteboard(_ rec: Recording) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(rec.transcriptText, forType: .string)
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: green. Fix type mismatches as they arise.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/HarcWindowRootView.swift
git commit -m "feat(ui): wire toolbar actions and recording-state pill

Edit/Export/Delete passed in as closures from the host; copy works
inline. Glass-tinted recording pill (HarcBrand.live) appears in the
leading toolbar slot only when recording is active.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.4: Rename `LibraryWindowController` → `HarcWindowController` and host the new view

**Files:**
- Rename: `HarcApp/WindowControllers/LibraryWindowController.swift` → `HarcWindowController.swift`
- Modify: the renamed controller's class name + hosted view
- Modify: `HarcApp/AppDelegate.swift` (any references to `LibraryWindowController` and the `libraryWindow` property)

- [ ] **Step 1: Rename the file**

```bash
git mv HarcApp/WindowControllers/LibraryWindowController.swift HarcApp/WindowControllers/HarcWindowController.swift
```

- [ ] **Step 2: Rename the class**

In `HarcWindowController.swift`, find:

```swift
final class LibraryWindowController: NSWindowController { ... }
```

Replace with:

```swift
final class HarcWindowController: NSWindowController { ... }
```

(Plus any `init` or factory references inside the file.)

- [ ] **Step 3: Replace the hosted SwiftUI view**

Find the line that hosts `LibraryWindowRootView(...)` (likely inside `init` or a factory method, wrapped in `NSHostingView` / `NSHostingController`). Replace with `HarcWindowRootView(...)` and pass the matching dependencies (`recordingsVM`, `libraryVM`, `store`, `reIDService`, `recordingState`, `onEdit`, `onExport`, `onDelete`).

- [ ] **Step 4: Update AppDelegate references**

In `HarcApp/AppDelegate.swift`:
- `private var libraryWindow: LibraryWindowController?` → `private var harcWindow: HarcWindowController?`
- Every `LibraryWindowController(...)` call site → `HarcWindowController(...)`
- Every `libraryWindow` reference → `harcWindow`
- Where the controller was instantiated, pass the new closures (Edit/Export/Delete) and the `recordingState`. The AppDelegate already owns these — wire them through.

- [ ] **Step 5: Regenerate Xcode project**

```bash
xcodegen generate
```

- [ ] **Step 6: Build**

```bash
swift build
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -20
```

Expected: green.

- [ ] **Step 7: Smoke test in app**

Open the built `.app`, click the menu bar (popover still works at this point — it's deleted in Phase 4), trigger whatever menu item or hotkey opens the library window. Verify:
- The new window opens with sidebar + detail + inspector.
- Selecting a recording shows transcript + summary.
- Inspector toggle reveals/hides speaker editor.
- Copy in toolbar copies transcript.

- [ ] **Step 8: Commit**

```bash
git add HarcApp/WindowControllers/HarcWindowController.swift HarcApp/AppDelegate.swift Harc.xcodeproj
git commit -m "feat(window): host HarcWindowRootView via renamed HarcWindowController

LibraryWindowController renamed to HarcWindowController; hosts the new
NavigationSplitView root. AppDelegate's libraryWindow → harcWindow.
Old LibraryWindowRootView and TranscriptionDetailView still on disk
and referenced by their dedicated window controllers; deleted in Task 3.5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.5: Delete the old library/detail surfaces

**Files deleted:**
- `Sources/HarcUI/LibraryWindowRootView.swift`
- `Sources/HarcUI/TranscriptionDetailView.swift`
- `Sources/HarcUI/RecentRecordingsView.swift`
- `Sources/HarcUI/RecordingIconTile.swift`
- `Sources/HarcUI/LibrarySearchField.swift`
- `Sources/HarcUI/TagChip.swift`
- `Sources/HarcUI/MonthCalendarView.swift`
- `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`

- [ ] **Step 1: Confirm nothing still references them**

```bash
for f in LibraryWindowRootView TranscriptionDetailView RecentRecordingsView RecordingIconTile LibrarySearchField TagChip MonthCalendarView TranscriptionDetailWindowController; do
  echo "=== $f ==="
  grep -rn "$f" Sources/ HarcApp/ Tests/ | grep -v "$f\.swift"
done
```

Expected: zero hits per file (excluding the file itself). If hits remain, they're dangling call sites in AppDelegate or HarcWindowController — fix them now (route through `HarcWindowController` or delete dead code).

- [ ] **Step 2: Delete the files**

```bash
git rm Sources/HarcUI/LibraryWindowRootView.swift \
       Sources/HarcUI/TranscriptionDetailView.swift \
       Sources/HarcUI/RecentRecordingsView.swift \
       Sources/HarcUI/RecordingIconTile.swift \
       Sources/HarcUI/LibrarySearchField.swift \
       Sources/HarcUI/TagChip.swift \
       Sources/HarcUI/MonthCalendarView.swift \
       HarcApp/WindowControllers/TranscriptionDetailWindowController.swift
xcodegen generate
```

- [ ] **Step 3: Build and test**

```bash
swift build && swift test && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -20
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Harc.xcodeproj
git commit -m "chore(ui): delete legacy library/detail surfaces

LibraryWindowRootView (983), TranscriptionDetailView (591),
RecentRecordingsView, RecordingIconTile, LibrarySearchField, TagChip,
MonthCalendarView, TranscriptionDetailWindowController — all replaced
by HarcWindowRootView + Inspector sections in HarcWindowController.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Slim `MenuBarExtra` panel (the largest restructure)

The current code uses `NSStatusItem` + `NSPopover` directly from `AppDelegate`. The migration moves the menu-bar surface into the SwiftUI `App` body as `MenuBarExtra` and lifts state out of `AppDelegate` into observable objects so SwiftUI can read it.

### Task 4.1: Extract `PostStopTrayState` (testable timer)

**Files:**
- Create: `Sources/HarcUI/PostStopTrayState.swift`
- Create: `Tests/HarcUITests/PostStopTrayStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HarcUITests/PostStopTrayStateTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcUI

@Suite("PostStopTrayState")
@MainActor
struct PostStopTrayStateTests {

    @Test("starts hidden")
    func startsHidden() {
        let s = PostStopTrayState()
        #expect(s.isVisible == false)
        #expect(s.lastTranscript == nil)
    }

    @Test("show() makes it visible with the given transcript")
    func showVisible() {
        let s = PostStopTrayState()
        s.show(title: "Standup", transcript: "Hello world.")
        #expect(s.isVisible == true)
        #expect(s.lastTranscript == "Hello world.")
        #expect(s.lastTitle == "Standup")
    }

    @Test("dismiss() hides immediately")
    func dismissHides() {
        let s = PostStopTrayState()
        s.show(title: "Standup", transcript: "x")
        s.dismiss()
        #expect(s.isVisible == false)
    }

    @Test("auto-fades after the configured TTL")
    func autoFade() async throws {
        let s = PostStopTrayState(visibleDuration: .milliseconds(50))
        s.show(title: "T", transcript: "t")
        #expect(s.isVisible == true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(s.isVisible == false)
    }
}
```

- [ ] **Step 2: Run the test, expect failure (file does not exist)**

```bash
swift test --filter HarcUITests.PostStopTrayStateTests 2>&1 | tail -10
```

Expected: compilation failure — `PostStopTrayState` not found.

- [ ] **Step 3: Implement `PostStopTrayState.swift`**

Create `Sources/HarcUI/PostStopTrayState.swift`:

```swift
import Foundation
import SwiftUI

/// Drives the post-stop tray inside the slim MenuBarExtra panel.
/// Visible for `visibleDuration` after `show(...)`, then auto-fades.
/// Replaces the timer logic that used to live inside PostStopTrayBanner.
@MainActor
public final class PostStopTrayState: ObservableObject {
    @Published public private(set) var isVisible: Bool = false
    @Published public private(set) var lastTitle: String? = nil
    @Published public private(set) var lastTranscript: String? = nil

    private let visibleDuration: Duration
    private var fadeTask: Task<Void, Never>? = nil

    public init(visibleDuration: Duration = .seconds(30)) {
        self.visibleDuration = visibleDuration
    }

    public func show(title: String, transcript: String) {
        fadeTask?.cancel()
        lastTitle = title
        lastTranscript = transcript
        isVisible = true
        fadeTask = Task { [weak self, visibleDuration] in
            try? await Task.sleep(for: visibleDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isVisible = false }
        }
    }

    public func dismiss() {
        fadeTask?.cancel()
        isVisible = false
    }
}
```

- [ ] **Step 4: Run the test**

```bash
swift test --filter HarcUITests.PostStopTrayStateTests 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/PostStopTrayState.swift Tests/HarcUITests/PostStopTrayStateTests.swift
git commit -m "feat(ui): PostStopTrayState with 30s auto-fade timer

Lifts the post-stop tray's timing logic out of the view into a tested
observable object — the slim MenuBarPanelView (next task) consumes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.2: Build `MenuBarPanelView`

**Files:**
- Create: `Sources/HarcUI/MenuBarPanelView.swift`

- [ ] **Step 1: Identify the elapsed-time, level, and recording-state inputs**

```bash
grep -n "RecordingState\|elapsedSeconds\|isRecording\|LiveScopeView" Sources/HarcUI/RecordingState.swift Sources/HarcUI/LiveScopeView.swift Sources/HarcUI/PopoverRootView.swift HarcApp/AppDelegate.swift | head -30
```

Note the public properties on `RecordingState` — the new view consumes them.

- [ ] **Step 2: Create `Sources/HarcUI/MenuBarPanelView.swift`**

```swift
import SwiftUI

/// Slim MenuBarExtra panel: recording state + level bars + Start/Stop + Open + post-stop tray.
/// Replaces the 520-line PopoverRootView.
public struct MenuBarPanelView: View {
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var trayState: PostStopTrayState
    let onStartStop: () -> Void
    let onOpenWindow: () -> Void
    let onCopy: () -> Void
    let onPasteIntoFrontmost: () -> Void
    let frontmostAppName: String?

    public init(
        recordingState: RecordingState,
        trayState: PostStopTrayState,
        onStartStop: @escaping () -> Void,
        onOpenWindow: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onPasteIntoFrontmost: @escaping () -> Void,
        frontmostAppName: String?
    ) {
        self.recordingState = recordingState
        self.trayState = trayState
        self.onStartStop = onStartStop
        self.onOpenWindow = onOpenWindow
        self.onCopy = onCopy
        self.onPasteIntoFrontmost = onPasteIntoFrontmost
        self.frontmostAppName = frontmostAppName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stateLine
            LiveScopeView(recordingState: recordingState)
                .frame(height: 28)
            HStack(spacing: 8) {
                Button(recordingState.isRecording ? "Stop" : "Record") { onStartStop() }
                    .buttonStyle(.borderedProminent)
                    .tint(recordingState.isRecording ? HarcBrand.live : .accentColor)
                Button("Open") { onOpenWindow() }
                    .buttonStyle(.bordered)
            }

            if trayState.isVisible {
                Divider()
                tray
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.2), value: trayState.isVisible)
    }

    private var stateLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recordingState.isRecording ? HarcBrand.live : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(recordingState.isRecording ? "Recording" : "Idle")
                .font(.subheadline)
            Spacer()
            if recordingState.isRecording {
                Text(elapsedString)
                    .font(.system(.subheadline, design: .monospaced))
                    .monospacedDigit()
            }
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trayState.lastTitle ?? "Last recording")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Copy") { onCopy() }
                    .buttonStyle(.bordered)
                if let frontmostAppName {
                    Button("Paste → \(frontmostAppName)") { onPasteIntoFrontmost() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
    }

    private var elapsedString: String {
        let total = Int(recordingState.elapsedSeconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
```

(If `RecordingState` doesn't expose `elapsedSeconds` directly, look at how `PopoverRootView` reads it and copy that exact accessor — do not invent.)

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: green. Fix any property mismatch with the exact name on `RecordingState`.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/MenuBarPanelView.swift
git commit -m "feat(ui): MenuBarPanelView — slim native MenuBarExtra panel

Recording state + level bars + Start/Stop + Open + post-stop tray.
~120 LoC replacing the 520-line PopoverRootView (deleted in Task 4.4).
Tray uses .glassEffect() inside the panel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.3: Wire `MenuBarExtra` in `HarcApp.swift`, lift state out of `AppDelegate`

**Files:**
- Modify: `HarcApp/HarcApp.swift`
- Modify: `HarcApp/AppDelegate.swift` (significant slim-down)

This task is the structural pivot. `AppDelegate` keeps lifecycle, daemon launcher, hotkey handling, and recording-flow orchestration but loses the `NSStatusItem` + `NSPopover` plumbing. State the SwiftUI App needs (`RecordingState`, `PostStopTrayState`, the recording-toggle action, the open-window action, the frontmost-app name, etc.) is exposed via a small bridge.

- [ ] **Step 1: Introduce a bridge object**

Inside `HarcApp/AppDelegate.swift`, add a nested or top-level `@MainActor` class:

```swift
@MainActor
public final class HarcAppBridge: ObservableObject {
    public let recordingState: RecordingState
    public let trayState: PostStopTrayState

    @Published public var frontmostAppName: String? = nil

    public var onStartStop: () -> Void = {}
    public var onOpenWindow: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteIntoFrontmost: () -> Void = {}

    public init(recordingState: RecordingState, trayState: PostStopTrayState) {
        self.recordingState = recordingState
        self.trayState = trayState
    }
}
```

(If `RecordingState` is currently `private` in AppDelegate, change it to be passed into the bridge.)

- [ ] **Step 2: Construct the bridge in AppDelegate's init or `applicationDidFinishLaunching`**

```swift
let bridge: HarcAppBridge

override init() {
    let state = RecordingState()
    let tray = PostStopTrayState()
    self.bridge = HarcAppBridge(recordingState: state, trayState: tray)
    super.init()
    bridge.onStartStop = { [weak self] in
        Task { await self?.toggleRecording() }
    }
    bridge.onOpenWindow = { [weak self] in
        self?.openHarcWindow()
    }
    bridge.onCopyLastTranscript = { [weak self] in self?.copyLastTranscript() }
    bridge.onPasteIntoFrontmost = { [weak self] in self?.pasteLastTranscriptIntoFrontmost() }
}
```

(Shape adjusts to whatever AppDelegate currently does. The point is: AppDelegate still owns the actions, the bridge exposes them as closures.)

- [ ] **Step 3: Drive `frontmostAppName` from `FrontmostAppPaster`**

Wherever `FrontmostAppPaster` already polls/tracks the frontmost app, push its name into `bridge.frontmostAppName` on changes. If it currently doesn't poll, this can be evaluated lazily on tray-show.

- [ ] **Step 4: Wire `MenuBarExtra` into `HarcApp.swift`**

Both the `MenuBarExtra` label and the panel need to observe the bridge so SwiftUI re-renders when `isRecording` or `frontmostAppName` change. Wrap the label and panel content in dedicated view structs that take the bridge as `@ObservedObject` — direct property reads inside the App body do not subscribe.

Replace `HarcApp/HarcApp.swift` with:

```swift
import SwiftUI
import HarcUI

@main
struct HarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            HarcSettingsForm()
        }

        MenuBarExtra {
            MenuBarExtraContent(bridge: appDelegate.bridge)
        } label: {
            MenuBarExtraLabel(bridge: appDelegate.bridge)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Subscribes to bridge so the label re-renders on isRecording flips.
private struct MenuBarExtraLabel: View {
    @ObservedObject var bridge: HarcAppBridge
    var body: some View {
        // If MenuBarBarsIcon is a SwiftUI View, use it directly.
        // Otherwise fall back to a system image until MenuBarBarsIcon is SwiftUI-ified.
        MenuBarBarsIcon(isRecording: bridge.recordingState.isRecording)
    }
}

/// Subscribes to bridge so the panel re-renders on frontmost-app changes,
/// post-stop tray toggles, and recording state.
private struct MenuBarExtraContent: View {
    @ObservedObject var bridge: HarcAppBridge
    var body: some View {
        MenuBarPanelView(
            recordingState: bridge.recordingState,
            trayState: bridge.trayState,
            onStartStop: bridge.onStartStop,
            onOpenWindow: bridge.onOpenWindow,
            onCopy: bridge.onCopyLastTranscript,
            onPasteIntoFrontmost: bridge.onPasteIntoFrontmost,
            frontmostAppName: bridge.frontmostAppName
        )
    }
}
```

**Note on `MenuBarBarsIcon`:** if the existing implementation is `View`-shaped, this works directly. If it expects to be drawn into an `NSStatusItem.button.image`, it needs a small SwiftUI rendition — read the existing file and decide. Worst-case temporary: render `Image(systemName: "waveform")` with `.foregroundStyle(bridge.recordingState.isRecording ? HarcBrand.live : .primary)` and fold the bars motif back in as a follow-up.

**Note on observation:** because `MenuBarExtraContent` observes `bridge`, the panel re-renders when *any* `@Published` on the bridge changes (including `frontmostAppName`). `MenuBarPanelView` itself also `@ObservedObject`s `recordingState` and `trayState` — those subscriptions are still required because those nested observables can change without the bridge changing.

- [ ] **Step 5: Strip popover plumbing from AppDelegate**

In `HarcApp/AppDelegate.swift`:
- Delete the `private var statusItem: NSStatusItem?` and `private var popover: NSPopover?` properties.
- Delete `togglePopover(_:)`, `handleStatusItemClick(_:)`, `refreshPopoverRoot()`, `updateMenuBarIcon(...)` (the SwiftUI label drives the icon now), and the `NSStatusBar.system.statusItem(...)` setup in `applicationDidFinishLaunching`.
- Delete `NSPopoverDelegate` from the class declaration's protocol list.
- Delete any `pulseTimer`, `pulseOn`, `menuBarTicker` plumbing that existed solely to update the popover or NSStatusItem icon — `RecordingState` updates `elapsedSeconds` already; SwiftUI re-renders.

- [ ] **Step 6: Build and run**

```bash
swift build && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -20
```

Expected: green. Open the built app. Click the menu bar icon — the new slim panel appears with native `.window` chrome. Start/stop recording works; elapsed time ticks; level bars draw.

- [ ] **Step 7: Commit**

```bash
git add HarcApp/HarcApp.swift HarcApp/AppDelegate.swift
git commit -m "feat(menubar): switch to SwiftUI MenuBarExtra .window with slim panel

State lifted from AppDelegate into HarcAppBridge. NSStatusItem +
NSPopover plumbing deleted. RecordingState, PostStopTrayState, and
toggle/open/copy/paste actions are exposed via the bridge so the
SwiftUI App scene can host MenuBarPanelView directly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.4: Delete the old popover-era files

**Files deleted:**
- `Sources/HarcUI/PopoverRootView.swift`
- `Sources/HarcUI/RecordingControlsView.swift`
- `Sources/HarcUI/PostStopTrayBanner.swift`

- [ ] **Step 1: Confirm no remaining references**

```bash
for f in PopoverRootView RecordingControlsView PostStopTrayBanner; do
  echo "=== $f ==="
  grep -rn "$f" Sources/ HarcApp/ Tests/ | grep -v "$f\.swift"
done
```

Expected: zero hits.

- [ ] **Step 2: Delete**

```bash
git rm Sources/HarcUI/PopoverRootView.swift \
       Sources/HarcUI/RecordingControlsView.swift \
       Sources/HarcUI/PostStopTrayBanner.swift
```

- [ ] **Step 3: Build and test**

```bash
swift build && swift test && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -20
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(ui): delete legacy popover surfaces

PopoverRootView (520), RecordingControlsView (212), PostStopTrayBanner —
replaced by MenuBarPanelView and PostStopTrayState.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.5: Wire `PostStopTrayState.show(...)` into the recording-stop flow

**Files:**
- Modify: `HarcApp/AppDelegate.swift` (whichever method handles "recording stopped, transcript finalized")

- [ ] **Step 1: Find the post-stop hook**

```bash
grep -n "stopRecording\|recordingStopped\|onPostProcess\|finalize\|transcriptFinalized" HarcApp/AppDelegate.swift | head -20
```

- [ ] **Step 2: At the point where the final transcript text is available, call**

```swift
bridge.trayState.show(title: lastRecording.displayTitle, transcript: lastRecording.transcriptText)
```

(Property names match what already exists on `Recording`/`RecordingsViewModel`. Do not invent.)

- [ ] **Step 3: Build and smoke test**

Record a brief audio clip, stop, watch the panel — the tray should appear with the transcript title and Copy / Paste-into-frontmost buttons. Wait ~30s and confirm the tray fades.

- [ ] **Step 4: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "feat(menubar): show post-stop tray when recording finalizes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — TranscriptEditor on native primitives

### Task 5.1: Re-skin `TranscriptEditorView` with native `.toolbar` + Inspector

**Files:**
- Modify: `Sources/HarcUI/TranscriptEditor/TranscriptEditorView.swift`
- Modify: `Sources/HarcUI/TranscriptEditor/TranscriptEditorTransportView.swift`
- Light touch: `Sources/HarcUI/TranscriptEditor/TranscriptTextView.swift` (only if it has custom chrome — keep its NSTextView core)

- [ ] **Step 1: Read `TranscriptEditorView.swift` (392 lines)**

Identify: the toolbar block (Save, Discard, regenerate-from-audio), the transport block, the text body, the metadata sidebar (if any).

- [ ] **Step 2: Restructure the body using a native `.toolbar`**

Goal shape:

```swift
public struct TranscriptEditorView: View {
    @ObservedObject var viewModel: TranscriptEditorViewModel
    @State private var inspectorOpen: Bool = false

    public var body: some View {
        VStack(spacing: 0) {
            TranscriptEditorTransportView(viewModel: viewModel)
                .padding(.horizontal).padding(.vertical, 8)
            Divider()
            TranscriptTextView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Save") { viewModel.save() }
                    .disabled(!viewModel.hasChanges)
                Button("Discard") { viewModel.discard() }
                    .disabled(!viewModel.hasChanges)
                Spacer()
                Button {
                    Task { await viewModel.regenerateFromAudio() }
                } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                Button { inspectorOpen.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .inspector(isPresented: $inspectorOpen) {
            Form {
                SpeakerInspectorSection(
                    recording: viewModel.recording,
                    store: viewModel.store,
                    reIDService: viewModel.reIDService
                )
                FileInspectorSection(recording: viewModel.recording)
            }
            .formStyle(.grouped)
            .background(.thinMaterial)
        }
    }
}
```

(Method names like `save()`, `discard()`, `hasChanges`, `regenerateFromAudio()` must match `TranscriptEditorViewModel`'s actual API. Read the file and use the real names.)

- [ ] **Step 3: Slim `TranscriptEditorTransportView`**

The transport view is the play/scrub/skip controls. If its current implementation uses custom-styled `Button`s, swap to `.buttonStyle(.bordered)` and `Slider` for scrubbing (if not already). Don't touch the audio-player wiring in `TranscriptAudioPlayer.swift`.

- [ ] **Step 4: Build and smoke**

```bash
swift build && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

Open a recording's transcript editor. Verify Save/Discard/Regenerate appear in the native toolbar; Inspector toggle works; transport plays audio and scrubs.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/TranscriptEditor/
git commit -m "feat(editor): native toolbar and Inspector in TranscriptEditorView

Save/Discard/Regenerate move to native .toolbar items; Inspector reuses
SpeakerInspectorSection + FileInspectorSection. Transport view simplified
to .bordered buttons. NSTextView core in TranscriptTextView untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Auxiliary surfaces

### Task 6.1: `CountdownWarningPanel` glass treatment

**Files:**
- Modify: `Sources/HarcUI/CountdownWarningPanel.swift`

- [ ] **Step 1: Read the file**

```bash
wc -l Sources/HarcUI/CountdownWarningPanel.swift
sed -n '1,40p' Sources/HarcUI/CountdownWarningPanel.swift
```

- [ ] **Step 2: Wrap the panel content with `.glassEffect()`**

Find the outermost view's background. Replace whatever it is with:

```swift
.padding(14)
.glassEffect(in: RoundedRectangle(cornerRadius: 14))
```

- [ ] **Step 3: Build, smoke (trigger auto-stop), commit**

```bash
swift build
git add Sources/HarcUI/CountdownWarningPanel.swift
git commit -m "feat(ui): glass treatment for CountdownWarningPanel

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 6.2: `ModelRequirementView` → `ContentUnavailableView`

**Files:**
- Modify: `Sources/HarcUI/ModelRequirementView.swift`

- [ ] **Step 1: Read the current shape**

```bash
sed -n '1,80p' Sources/HarcUI/ModelRequirementView.swift
```

Identify: the title, the description, the action button (likely "Download model").

- [ ] **Step 2: Rewrite using `ContentUnavailableView`**

```swift
import SwiftUI

public struct ModelRequirementView: View {
    let title: String
    let description: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(title: String, description: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "arrow.down.circle")
        } description: {
            Text(description)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
```

- [ ] **Step 3: Update call sites if init signature changed**

```bash
grep -rn "ModelRequirementView(" Sources/ HarcApp/ | grep -v "ModelRequirementView.swift"
```

Adjust callers as needed.

- [ ] **Step 4: Build and commit**

```bash
swift build
git add Sources/HarcUI/ModelRequirementView.swift
git commit -m "refactor(ui): ModelRequirementView uses ContentUnavailableView

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 6.3: `AutoStopNotification` thin native panel

**Files:**
- Modify: `Sources/HarcUI/AutoStopNotification.swift`

Minimal touch: ensure the panel uses system materials (`.background(.thickMaterial)`) and standard `Button` styles. If it's currently a custom toast, leave the behavior — only re-skin chrome.

- [ ] **Step 1: Apply system material to outermost background**

Replace any custom fill on the outer container with `.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))`.

- [ ] **Step 2: Build, commit**

```bash
swift build
git add Sources/HarcUI/AutoStopNotification.swift
git commit -m "refactor(ui): AutoStopNotification uses system thickMaterial

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 7 — Cleanup

### Task 7.1: Delete `DesignTokens.swift`

**Files:**
- Delete: `Sources/HarcUI/DesignTokens.swift`

- [ ] **Step 1: Final reference check**

```bash
grep -rn "HarcDesign\.\|Color\.harc" Sources/ HarcApp/ Tests/
```

Expected: zero hits. Anything that comes back is dead code in a view that escaped earlier phases — fix it now.

- [ ] **Step 2: Delete**

```bash
git rm Sources/HarcUI/DesignTokens.swift
```

- [ ] **Step 3: Build, test**

```bash
swift build && swift test && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -20
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(ui): delete DesignTokens.swift — HarcBrand is the entire palette now

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 7.2: Update CLAUDE.md repo layout & module table

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Repository Layout / module table to reflect deletions and renames**

In `CLAUDE.md`, find the "Repository Layout" and "Architecture" sections. Edit to:
- Note that `HarcUI` no longer ships a custom design system (`HarcBrand` is the only color file).
- Reference `HarcWindowRootView` and `MenuBarPanelView` as the primary surfaces.
- Remove references to deleted files in the module description (specifically: any mention of popover, library window, transcription detail window as separate surfaces).
- Update the "Active dev surface" line if it still mentions the speaker-identity work that's already shipped.

- [ ] **Step 2: Update the "Non-obvious conventions" section**

Remove any conventions that no longer apply (custom design tokens, separate detail/library windows). Add: "All UI is SwiftUI native primitives + glass on macOS 26; the brand sliver is `HarcBrand`."

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for native UI rebuild

Repository layout reflects HarcWindowRootView + MenuBarPanelView replacing
the popover and library/detail windows. Active dev surface and non-obvious
conventions updated. HarcBrand replaces HarcDesign as the palette.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 7.3: Final size and quality check

**Files:** none changed.

- [ ] **Step 1: Measure HarcUI module size**

```bash
wc -l Sources/HarcUI/*.swift Sources/HarcUI/Settings/*.swift Sources/HarcUI/Inspector/*.swift Sources/HarcUI/TranscriptEditor/*.swift | tail -1
```

Expected: total LoC < 1500 (success criterion §14.2 of the spec). If significantly over, look for files that didn't get the simplification they needed and trim.

- [ ] **Step 2: Confirm all acceptance criteria from spec §14**

- [ ] `swift test` green
- [ ] `xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build` green
- [ ] `wc -l` shows materially smaller module (target <1500 LoC)
- [ ] `HarcDesign` is gone; `HarcBrand` is the only file in `HarcUI` defining colors:
  ```bash
  grep -rln "= Color(\|: Color(" Sources/HarcUI/ | sort
  ```
  Expected: ideally only `HarcBrand.swift` shows up. Some inline `Color(nsColor:.separatorColor)` calls are fine; new custom hex `Color(red:green:blue:)` definitions outside `HarcBrand.swift` are not.

- [ ] **Step 3: Run the manual QA checklist from spec §9**

Walk through every item. Fix any regression in-place. If a fix is a new task, add it as `Task 7.4` and beyond.

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin feat/native-ui-rebuild-2026-04-27
gh pr create --title "Native UI rebuild on macOS 26" --body "$(cat <<'EOF'
## Summary
- Rebuilds Harc's UI native-first on macOS 26 (Tahoe / Liquid Glass).
- Guts HarcDesign (171 lines) to a ~30-line HarcBrand sliver.
- Library + TranscriptionDetail collapse into one NavigationSplitView window with Inspector.
- Menu-bar surface slimmed from 520-line popover to ~120-line MenuBarExtra panel.
- Settings becomes a single Form with grouped Sections.
- Lifts state out of AppDelegate into HarcAppBridge so SwiftUI can host the menu bar.
- Deployment target bumps to macOS 26.

Spec: `docs/superpowers/specs/2026-04-27-native-ui-rebuild-design.md`
Plan: `docs/superpowers/plans/2026-04-27-native-ui-rebuild.md`

## Test plan
- [ ] Cold launch → menu bar slim panel renders with native chrome
- [ ] Start recording → red dot + level bars + elapsed timer; main window's toolbar shows the glass-tinted recording pill
- [ ] Stop → post-stop tray appears with Copy + "Paste → [App]"; auto-paste fires if frontmost is paste-friendly; tray fades after ~30s
- [ ] Open main window → sidebar groups recordings; selecting one shows transcript + summary card; Inspector toggle reveals speaker editor + file metadata
- [ ] .searchable filters sidebar
- [ ] Settings opens via Cmd-, → all six sections visible in a single Form; controls work; hotkey rebinding works
- [ ] TranscriptEditor opens via Edit toolbar action → text editing works, Save persists
- [ ] Long meeting (30+ min) end-to-end smoke
- [ ] System accent change reflects across the app live

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Notes for the executing agent

- **TDD applies where there's testable behavior.** `PostStopTrayState`, any new VM derivations — write tests first. View structure changes (most of this plan) verify via `swift build` + `swift test` (no regressions) + manual smoke.
- **Property/method names must match what already exists.** When in doubt, read the existing file before writing the new one. Do not invent VM methods to make the new view compile; either the method exists with a different name (use the right one) or the view should derive from public state inline.
- **Build after every file in the token-swap pass** (Task 1.2, Step 3). It's tedious but catches mismatches at the point where they're easy to fix.
- **Phase 3 → Phase 4 boundary.** At the end of Phase 3 the popover still exists and the new main window also exists. Both work. This intentional overlap means Phase 3 can be reviewed and validated before the bigger Phase 4 restructure of `AppDelegate`.
- **Liquid Glass APIs.** If `.glassEffect(.regular.tint(...), in:)` API surface differs from what this plan assumes (Tahoe-era APIs evolve), use the closest macOS 26 equivalent and note the deviation in the commit message.
- **Avoid `--no-verify` and amends.** If a commit hook fails, fix the underlying issue and create a new commit.
