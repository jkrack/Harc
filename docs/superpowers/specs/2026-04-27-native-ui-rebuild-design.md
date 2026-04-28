# Native UI Rebuild — Design Spec

**Date:** 2026-04-27
**Status:** Approved (brainstorming complete; awaiting plan)
**Owner:** J
**Branch:** `feat/native-ui-rebuild-2026-04-27` (to be created)

## 1. Problem

Harc's current UI is heavy with custom code: a parallel design system (`HarcDesign`, ~170 lines of hex tokens, custom typography roles, custom spacing/radius scales), a custom `GlassBackground`, and ~5K LoC across hand-rolled views (`PopoverRootView` 520, `LibraryWindowRootView` 983, `TranscriptionDetailView` 591, plus auxiliaries). Most of what these files do is reproduce, by hand, what SwiftUI on macOS 26 ships natively: `NavigationSplitView`, `Inspector`, `Form` with `.formStyle(.grouped)`, `MenuBarExtra` window-style panel, `.glassEffect()`, system materials, and `Color.accentColor`.

The result is a utility app that feels cross-platform rather than unmistakably Mac-native, and a UI codebase that is expensive to evolve. We are rebuilding the UI to be native-first on macOS 26 (Tahoe / Liquid Glass), with a minimal brand sliver.

This redesign does **not** touch the audio pipeline, daemon IPC, GRDB schema, summarization, speaker re-ID logic, or hotkey integration. It is contained to `HarcUI` and `HarcApp`.

## 2. Goals

- Replace custom UI scaffolding with native SwiftUI primitives wherever possible.
- Reduce `HarcUI` LoC materially (target: <1500 LoC; currently ~5K+).
- Adopt Liquid Glass and Tahoe materials where macOS 26 makes them automatic; opt in explicitly only where it adds clear value.
- Collapse the most painful window split (Library + TranscriptionDetail) into one `NavigationSplitView` window.
- Slim the menu-bar surface from a 520-line custom popover to a small `MenuBarExtra.window`-style panel that preserves the load-bearing post-stop tray.
- Preserve a tiny brand sliver: recording red, app-icon gradient, menu-bar bars motif.

## 3. Non-goals

- Multilingual STT, push-to-talk, cloud STT — already non-goals per CLAUDE.md.
- Backwards compatibility with macOS 14/15 — deployment target moves to macOS 26.
- Inline transcript editing inside the main window — `TranscriptEditor` remains a separate focused window.
- Audio pipeline, daemon, store, or summarization changes.
- A two-design-vocabulary transition state — we are not doing surface-by-surface rollouts that leave the app half-converted.

## 4. Hard decisions made during brainstorming

| Decision | Choice |
|---|---|
| Aesthetic vs. structural rework | Both, but structural changes only where they fall naturally out of going native. |
| How far to go native | Native-first with a thin brand layer. |
| Deployment target | macOS 26 only. CLAUDE.md hard constraint updated as part of the rebuild. |
| Brand sliver | Minimal: recording red + app-icon gradient + menu-bar bars motif. Everything else system. |
| Window model | Hybrid — Library + Detail merge into one `NavigationSplitView` window. `TranscriptEditor` and Settings stay separate windows. Menu bar slimmed. |
| Menu-bar surface | Slim `MenuBarExtra.window` panel with recording controls + post-stop Copy/Paste tray. No recents strip. |
| Rollout shape | Single coherent rollout on one branch. |

## 5. Design language mapping

`HarcDesign` (171 lines) is replaced by `HarcBrand` (~30 lines). Every token migrates to a system equivalent:

```swift
public enum HarcBrand {
    /// Recording / "live" red. Drives menu-bar dot, recording chrome.
    public static let live = Color(red: 0xF0/255, green: 0x55/255, blue: 0x4D/255)

    /// Brand gradient. App icon, About panel only.
    public static let gradient = LinearGradient(
        colors: [Color(red: 0x70/255, green: 0xA3/255, blue: 0xFF/255),
                 Color(red: 0x33/255, green: 0x5C/255, blue: 0xE0/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
```

`MenuBarBarsIcon` survives unchanged. `GlassBackground.swift` is deleted.

### Token migration table

| Old token | Replaced by |
|---|---|
| `surface0` (app bg) | `Color(nsColor: .windowBackgroundColor)` or no fill (let materials show) |
| `surface1` (sidebar / rail) | `.background(.regularMaterial)` or default sidebar styling |
| `surface2` (card) | `.background(.thickMaterial)` or `.background(.background.secondary)` |
| `surface3` / `surface4` (hover/pressed) | Native control hover/press states |
| `borderSubtle` / `borderStrong` | `Divider()` or `.background.tertiary`. No custom 1pt strokes. |
| `inkPrimary` | `Color.primary` |
| `inkSecondary` | `Color.secondary` |
| `inkTertiary` | `.secondary.opacity(0.7)` or `Color(nsColor: .tertiaryLabelColor)` |
| `inkQuaternary` | `Color(nsColor: .quaternaryLabelColor)` |
| `accent` / `accentHover` / `accentSoft` | `Color.accentColor` |
| `selection` / `selectionEdge` | Native `List` selection — no manual fill |
| `success` / `warning` / `danger` | `.green` / `.yellow` / `.red` |
| `live` | `HarcBrand.live` (kept) |
| `chipBg` / `chipInk` | `.background(.background.tertiary)` for fill, `Color.primary` for ink |
| `Font.display` (28pt semibold) | `.font(.largeTitle).fontWeight(.semibold)` |
| `Font.title` (17pt semibold) | `.font(.title3).fontWeight(.semibold)` |
| `Font.subtitle` (15pt semibold) | `.font(.headline)` |
| `Font.body` / `bodyMd` | `.font(.body)` |
| `Font.bodySm` / `meta` | `.font(.callout)` or `.font(.subheadline)` |
| `Font.label` / `labelMd` | `.font(.caption)` or `.font(.caption2)` |
| `Font.mono` / `monoMd` / `monoXs` | `.font(.system(.callout, design: .monospaced))` etc. |
| `Space.s1`–`s8` | Default SwiftUI spacing; rare explicit values use raw numbers |
| `Radius.sm` / `md` / `lg` / `xl` | Default control radii; if explicit, raw numbers (4/6/8/12) |
| `Layout.sidebarWidth` / `railWidth` | `NavigationSplitView` defaults; user can resize |
| `primaryGradient` (legacy alias) | Removed; only `HarcBrand.gradient` remains |
| All `Color.harc*` extensions | Deleted |

### Implications

- System accent wins: if the user's system accent is graphite, Harc's accent is graphite. Brand blue survives only on the app icon and About panel.
- App follows system Light/Dark/Auto via materials — no more "always-dark utility app."
- No more semantic color tokens for `success`/`warning`/`danger` — system semantic colors handle adaptation.
- No spacing scale; SwiftUI defaults handle 99% of cases.
- Tag chips become tertiary-fill backgrounds, not custom blue tint.

## 6. Surface inventory & treatment

### 6.1 Main window — new `HarcWindowRootView`

`NavigationSplitView` with three columns: sidebar (recordings list + filters), detail (transcript + summary), inspector (speakers + metadata).

| Column | Native primitive | Replaces |
|---|---|---|
| Sidebar | `List` with `.listStyle(.sidebar)`, `.searchable(text:)`, sections for "Pinned" / "Today" / month groups | `LibraryWindowRootView` (983), `LibrarySearchField`, `MonthCalendarView` |
| Detail | `ScrollView` with native `Text`, `GroupBox` for summary card, `.toolbar` for Copy/Export/Edit/Delete/Inspector toggle | `TranscriptionDetailView` (591), `SummaryCardView` (re-skinned to GroupBox) |
| Inspector | `.inspector(isPresented:)` with `Form { Section("Speakers") { ... }; Section("File") { ... } }` | Inline speaker editor + metadata in current detail view |

Toolbar uses `.toolbar { ToolbarItem ... }` — system applies glass treatment automatically on macOS 26.

### 6.2 Menu-bar surface — slim `MenuBarExtra` panel

`MenuBarExtra("Harc", systemImage: ...) { ... }.menuBarExtraStyle(.window)` — auto glass on Tahoe.

```
┌─────────────────────────┐
│ ●  Recording  00:14:32  │   state line (red dot + monospaced timer)
│ ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌ │   level bars (LiveScopeView)
│ ┌──────────┬──────────┐ │
│ │  Stop    │   Open   │ │
│ └──────────┴──────────┘ │
│ ─────────────────────── │
│ Last: "Standup 04/27"   │   post-stop tray (30s fade)
│ ┌──────────┬──────────┐ │
│ │   Copy   │ Paste→Slk│ │
│ └──────────┴──────────┘ │
└─────────────────────────┘
```

| Element | Native primitive | Replaces |
|---|---|---|
| Panel container | `MenuBarExtra` `.window` style (auto glass) | Custom popover + `GlassBackground` |
| State line | `HStack { Circle().fill(HarcBrand.live); Text("Recording"); Spacer(); Text(elapsed).monospacedDigit() }` | Custom HStack in `PopoverRootView` |
| Level bars | `LiveScopeView` (kept) | Same |
| Buttons | `.buttonStyle(.borderedProminent)` for primary, `.bordered` for secondary | Custom-styled buttons |
| Post-stop tray | Inline `VStack` with two `Button`s, `.transition(.opacity)` driven by 30s timer | `PostStopTrayBanner` |

`PopoverRootView`, `RecentRecordingsView`, `RecordingIconTile`, `RecordingControlsView`, `PostStopTrayBanner` — all deleted after parity.

### 6.3 Settings — `Settings {}` scene with `Form`

Single `Form` with grouped `Section`s replacing the six-tab `TabView`. If `KeyboardShortcuts.Recorder` doesn't render cleanly inside a `Form`, Hotkeys remains a `TabView` tab while the rest collapses to sections.

| Section | Contents |
|---|---|
| General | Launch at login, default destination folder, theme follows system |
| Recording | Sample rate (locked), system-audio toggle, mic device picker |
| Transcription | Diarize-by-default toggle, chunk size (advanced) |
| Speakers | Speaker re-ID toggle, threshold slider, "Forget all speakers" |
| Hotkeys | `KeyboardShortcuts.Recorder` per action |
| Summarization | Model picker, prompt template |

`Form` with `.formStyle(.grouped)`. `SettingsWindowController.swift` is deleted (the `Settings {}` scene manages its own window).

### 6.4 TranscriptEditor — separate window, native primitives

Stays its own window. `NSWindowController` wrapping a SwiftUI view with native `.toolbar` (Save, Discard, Regenerate from audio), `TextEditor` for the body, and the same `Inspector` the main window uses for speakers.

### 6.5 Auxiliary surfaces

| Surface | Treatment |
|---|---|
| `MenuBarBarsIcon` | Kept as-is (brand sliver) |
| `MenuBarFlash` | Kept; brief tint flash on state change |
| `CountdownWarningPanel` | Floating panel with `.glassEffect()` |
| `AutoStopNotification` | `UserNotifications` or thin native panel |
| `ModelRequirementView` | Replaced by `ContentUnavailableView` |
| `SummaryCardState` / `ActiveSummarizerReconciler` / `MeetingDetectionState` | Untouched (pure state) |

### 6.6 Files deleted

`PopoverRootView.swift`, `LibraryWindowRootView.swift`, `TranscriptionDetailView.swift`, `RecentRecordingsView.swift`, `RecordingIconTile.swift`, `RecordingControlsView.swift`, `PostStopTrayBanner.swift`, `LibrarySearchField.swift`, `TagChip.swift`, `GlassBackground.swift`, `MonthCalendarView.swift`, `TranscriptionDetailWindowController.swift`, `SettingsWindowController.swift`, plus any wrappers in `Settings/` that exist solely to host custom-styled rows.

### 6.6.1 Files renamed

`LibraryWindowController.swift` → `HarcWindowController.swift` (now hosts the merged Library + Detail view).

### 6.7 Files kept

`MenuBarBarsIcon`, `MenuBarFlash`, `LiveScopeView`, `SummaryCardView` (re-skinned), `SpeakerNameEditor` (re-skinned), `SpeakerSuggestionChip` (re-skinned), `TranscriptHitRow` (becomes plain `List` row content), `ModelRequirementView` (becomes `ContentUnavailableView` wrapper), all `*ViewModel` / `*State` / `*Reconciler` files (UI-agnostic).

## 7. Glass / Tahoe specifics

### 7.1 Automatic (no code beyond the deployment bump)

- Toolbars on `NavigationSplitView` get the Liquid Glass treatment.
- `List` with `.listStyle(.sidebar)` picks up the Tahoe sidebar material.
- `MenuBarExtra` `.window` style paints with system glass chrome.
- `Form` with `.formStyle(.grouped)` gets the inset-grouped Tahoe look.
- `.background(.regularMaterial)` and friends auto-translate to new vibrancy.
- Selection / hover / press states are system-managed and vibrancy-aware.

### 7.2 Explicit opt-ins

| Surface | Treatment | Why explicit |
|---|---|---|
| Inspector pane background | `.background(.thinMaterial)` | `.inspector` doesn't pick a material by default |
| Floating post-stop tray inside the MenuBarExtra panel | `.glassEffect(in: RoundedRectangle(cornerRadius: 10))` | Distinct floating chip inside the panel |
| Recording-state pill in the main window toolbar | `.glassEffect(.regular.tint(HarcBrand.live), in: Capsule())` when active | Brand red intentionally tints glass for the app's primary state |
| `SummaryCardView` background | `.background(.background.secondary)` (no glass) | Reads as content, not chrome |
| `CountdownWarningPanel` | `.glassEffect(in: RoundedRectangle(cornerRadius: 14))` | Floating warning |

### 7.3 Surfaces explicitly NOT glassed

- Transcript text background — flat. Long-form text on glass is hostile.
- Settings `Form` rows — Tahoe handles them; manual glass would fight the system.
- Sidebar list rows.
- `SpeakerSuggestionChip` — too small/repeated; flat tertiary fill is cleaner.

### 7.4 Tinting

`Color.accentColor` participates in glass tinting on macOS 26. We use explicit tint exactly **once** — the recording pill, with `HarcBrand.live`. Everything else stays untinted glass. Idiomatic Tahoe: glass is mostly clear; tint is reserved for state that matters.

### 7.5 Fallback

None. Deployment is macOS 26.

## 8. Migration sequence

Each step leaves the project compiling and `swift test` green so commit-by-commit review is viable.

### Step 0 — branch, deploy bump
- Create `feat/native-ui-rebuild-2026-04-27`.
- `Package.swift` platforms → `.macOS(.v26)`.
- `project.yml` deploymentTarget → 26.0; `xcodegen generate`.
- CLAUDE.md "Hard Constraints": macOS 26+.

### Step 1 — gut `HarcDesign`, introduce `HarcBrand`
- Replace `Sources/HarcUI/DesignTokens.swift` with `HarcBrand`.
- Mechanical token swap (Section 5 table) across every UI file.
- Delete `GlassBackground.swift`.
- Project builds; `swift test` passes.

### Step 2 — Settings as `Settings {}` scene with `Form`
- Rewrite `SettingsView.swift` and `Settings/` subdir as a single `Form` with `Section`s (or `TabView` only for Hotkeys if needed).
- Wire from `HarcApp` `App` body via `Settings { ... }`.
- Delete `SettingsWindowController.swift`.

### Step 3 — `HarcWindowRootView` (Library + Detail collapse)
- Build new `HarcWindowRootView.swift` from scratch using `NavigationSplitView` + `.searchable` + `.toolbar` + `.inspector`.
- Bind to existing `RecordingsViewModel`.
- Migrate detail content to native `Text` + `GroupBox` summary + native toolbar.
- Build inspector with `Form` Sections for Speakers and File.
- Rename `LibraryWindowController` → `HarcWindowController`, host the new view.
- Delete the surfaces listed in §6.6.

### Step 4 — slim `MenuBarExtra` panel
- Rewrite the `MenuBarExtra` declaration in `HarcApp` with `.window` style + a small `MenuBarPanelView`.
- Wire `RecordingsViewModel` and post-stop state for the tray.
- Delete `PopoverRootView`, `RecordingControlsView`, `PostStopTrayBanner`.

### Step 5 — `TranscriptEditor` on native primitives
- Rebuild views in `Sources/HarcUI/TranscriptEditor/` on `TextEditor` + native `.toolbar` + reused Inspector.
- Update `TranscriptEditorWindowController`.

### Step 6 — auxiliary surfaces
- `CountdownWarningPanel` → glass floating panel.
- `AutoStopNotification` → `UserNotifications` or thin native panel.
- `ModelRequirementView` → `ContentUnavailableView`.

### Step 7 — cleanup pass
- Remove dead code, leftover `harc*` extensions, unused imports.
- `swift build`, `swift test`, `xcodebuild` all clean.
- Update CLAUDE.md "Repository Layout" / "Architecture" / module table for new and removed files.

## 9. Manual QA checklist (PR description)

- Cold launch → menu bar → main window opens via "Open Harc"
- Start recording from menu bar panel → red pill in main-window toolbar; level bars in panel
- Stop → post-stop tray appears in panel; auto-paste fires (or Copy works manually)
- Tray fades after ~30s
- Open main window → transcript visible in detail pane; Inspector toggle reveals speaker editor
- `.searchable` query filters sidebar
- Settings opens via Cmd-, → all sections render natively, hotkey rebinding still works
- TranscriptEditor opens via Edit toolbar button → text editing works, Save persists
- Long meeting (30+ min) end-to-end smoke
- System accent change live-reflects across the app

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | macOS 26 deployment cuts off some users | Deliberate (Q4-A). Tag `v-pre-tahoe` before merge so older users have a fallback build. |
| 2 | Big PR is hard to review | Step sequence in §8 makes each commit a reviewable unit. PR description points at commit-by-commit. Fallback: split into "foundation" (Steps 0–2) + "views" (Steps 3–7). |
| 3 | Liquid Glass APIs change between Xcode versions | Pin Xcode version in CI; document working version in CLAUDE.md Build & Run. |
| 4 | `NavigationSplitView` + `Inspector` quirks | Build a small SwiftUI prototype during Step 3 before committing to the structure; fall back to `HSplitView` if needed. |
| 5 | Auto-paste flow regressions when post-stop tray moves into the slim panel | Explicit manual QA for four scenarios: auto-paste succeeds, denied by deny-list, fails silently, user dismisses. Add a Swift Testing case for tray timer state. |
| 6 | `KeyboardShortcuts.Recorder` doesn't sit cleanly inside `Form` | Prototype in Step 2; Hotkeys keeps `TabView` if needed (already accommodated). |
| 7 | System accent on graphite/multicolor clashes with brand red recording pill | Manual QA includes accent cycling. |

## 11. Things explicitly cut

- Custom blue accent everywhere except app icon and About panel.
- Custom dark surface stops (`surface0`–`surface4`); app follows system Light/Dark/Auto.
- `MonthCalendarView` as a custom widget (replaced by `DatePicker` filter or sectioned sidebar).
- `TagChip` custom styling (replaced by tertiary-fill native chips).
- `GlassBackground.swift`.
- `HarcDesign.Layout` explicit sizes.
- 6-tab Settings (becomes `Form` sections, Hotkeys possibly excepted).
- 520-line popover (replaced by ~80–120 line `MenuBarPanelView`).

## 12. Things explicitly preserved

- All non-UI behavior: daemon lifecycle, IPC, audio capture, durable WAV write strategy, GRDB schema (still v9), summarization queue, meeting detection, speaker re-ID logic.
- Recording state semantics: red dot, "Recording" copy, monospaced timer, level bars.
- Auto-paste flow (different host surface).
- Hotkeys (`KeyboardShortcuts` integration unchanged).
- Brand identity at the menu bar (bars motif) and the app icon.

## 13. Open questions to resolve during implementation

- Whether to show a glass-tinted recording pill in the main window toolbar in addition to the menu-bar bars icon. 5-minute prototype call during Step 3.
- `MonthCalendarView` replacement: `DatePicker` filter vs. sectioned sidebar — decide during Step 3 with the actual sidebar in front.
- Inspector default state: open or closed. Default closed, transcript front and center.

## 14. Success criteria

1. `swift test` and `xcodebuild` both green.
2. `wc -l Sources/HarcUI/*.swift` shows the module materially smaller (target: <1500 LoC, currently ~5K+).
3. Manual QA checklist (§9) passes end-to-end on a Mac running macOS 26.
4. `HarcDesign` is gone; `HarcBrand` is the only file in `HarcUI` that defines colors.
5. App opens, records, transcribes, and presents the transcript using surfaces that a macOS 26 user describes as "feels native."
