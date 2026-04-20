# Auto-paste on Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the unconditional auto-paste-on-stop into a user-controlled, guarded, visibly-confirmed behavior: `HarcPreferences.autoPasteEnabled` toggle (default on), compile-time `PasteDenyList`, pure `AutoPasteGuard` decision, menu-bar icon flash for feedback, one-shot accessibility prompt, and two escape hatches (hold Shift while stopping via popover, or ⌥-click the status-item icon).

**Design doc:** `/Users/jlane/GitHub/Harc/docs/superpowers/specs/2026-04-19-auto-paste-design.md`

**Architecture:** New types live in HarcUI (`PasteDenyList`, `AutoPasteDecision` + `AutoPasteGuard`, `MenuBarFlash`). `HarcPreferences` gains one bool. `FrontmostAppPaster` gains a `frontmostBundleID()` helper. `RecordingSettingsView` gains a new section. `AppDelegate` replaces the current unconditional `FrontmostAppPaster.copyAndPaste(text)` block at line 242–244 with a guarded `runAutoPaste(for:)` flow that captures frontmost-app state, runs `AutoPasteGuard.decide`, paste+flashes on success, and surfaces a one-shot accessibility modal when Cmd-V synthesis is denied.

**Tech Stack:** Swift 6, AppKit (`NSStatusItem`, `NSWorkspace`, `NSEvent`, `NSAlert`), SwiftUI (Settings Form), Swift Testing, no new third-party deps.

---

## Dependency graph

```
Task 1 (PasteDenyList)
  └─▶ Task 2 (AutoPasteDecision + AutoPasteGuard)

Task 3 (HarcPreferences.autoPasteEnabled)   — independent
Task 4 (FrontmostAppPaster.frontmostBundleID) — independent
Task 5 (MenuBarFlash)                        — independent

Tasks 1-5 all feed into:
  └─▶ Task 6 (RecordingSettingsView: Auto-paste section)  (depends on T3 only)
  └─▶ Task 7 (AppDelegate: runAutoPaste + accessibility modal + wire into stopRecording)
           └─▶ Task 8 (⌥-click status-item escape hatch)
                    └─▶ Task 9 (end-to-end manual verification)
```

Tasks 1–5 may be parallelised (no mutual dependencies). Tasks 2 depends on 1.

---

## Effort summary

| Task | Effort | Gates |
|------|--------|-------|
| 1. `PasteDenyList` | S | `swift test --filter PasteDenyListTests` |
| 2. `AutoPasteDecision` + `AutoPasteGuard` | S | `swift test --filter AutoPasteGuardTests` |
| 3. `HarcPreferences.autoPasteEnabled` | S | `swift test --filter HarcPreferencesTests` |
| 4. `FrontmostAppPaster.frontmostBundleID()` | S | `swift build` |
| 5. `MenuBarFlash` | S | `swift build` + `xcodebuild` |
| 6. `RecordingSettingsView` — Auto-paste section | S | `xcodebuild` + manual |
| 7. `AppDelegate` — `runAutoPaste` + accessibility modal + wiring | M | `xcodebuild` + manual |
| 8. ⌥-click status-item escape hatch | S | `xcodebuild` + manual |
| 9. End-to-end manual verification | S | full `swift test`, smoke checklist |

---

### Task 1: `PasteDenyList`

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/PasteDenyList.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/PasteDenyListTests.swift`

- [ ] **Step 1: Write the failing test**

Create `/Users/jlane/GitHub/Harc/Tests/HarcUITests/PasteDenyListTests.swift`:

```swift
import Testing
import Foundation
import HarcUI

@Suite("PasteDenyList")
struct PasteDenyListTests {
    @Test("seed contains the critical bundle IDs")
    func seedContainsCriticalIDs() {
        let expected: Set<String> = [
            "com.apple.loginwindow",
            "com.agilebits.onepassword8",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.apple.finder",
        ]
        #expect(expected.isSubset(of: PasteDenyList.bundleIDs))
    }

    @Test("isDenied — nil returns false")
    func isDeniedNil() {
        #expect(PasteDenyList.isDenied(nil) == false)
    }

    @Test("isDenied — unknown bundle returns false")
    func isDeniedUnknown() {
        #expect(PasteDenyList.isDenied("com.unknown.app") == false)
    }

    @Test("isDenied — known bundle returns true")
    func isDeniedKnown() {
        #expect(PasteDenyList.isDenied("com.apple.finder") == true)
        #expect(PasteDenyList.isDenied("com.agilebits.onepassword7") == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PasteDenyListTests`
Expected: compile error — `PasteDenyList` does not exist.

- [ ] **Step 3: Create `PasteDenyList.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcUI/PasteDenyList.swift`:

```swift
import Foundation

/// Bundle IDs that are never safe auto-paste targets. Seed list — not
/// user-editable in v1 (see spec §8). `isDenied(nil)` returns `false` so
/// callers can pass the optional return of
/// `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` without
/// unwrapping.
public enum PasteDenyList {
    public static let bundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.ScreenSaver.Engine",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword8",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "us.zoom.xos",
        "com.microsoft.teams2",
    ]

    public static func isDenied(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PasteDenyListTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/PasteDenyList.swift Tests/HarcUITests/PasteDenyListTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): PasteDenyList seed + isDenied(_:) predicate

Compile-time Set<String> of bundle IDs that are never safe auto-paste
targets: loginwindow, Finder, System Settings, screensaver, major
password managers, Zoom, Teams. isDenied(nil) returns false.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `AutoPasteDecision` + `AutoPasteGuard`

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/AutoPasteDecision.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/AutoPasteGuardTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `/Users/jlane/GitHub/Harc/Tests/HarcUITests/AutoPasteGuardTests.swift`:

```swift
import Testing
import Foundation
import HarcUI

@Suite("AutoPasteGuard")
struct AutoPasteGuardTests {
    @Test("decide — matrix", arguments: [
        // (enabled, shiftHeld, bundleID, expected)
        (false, false, String?.none,                         AutoPasteDecision.skipDisabled),
        (false, true,  String?.none,                         .skipDisabled),
        (false, false, String?.some("com.example.foo"),      .skipDisabled),
        (true,  true,  String?.none,                         .skipModifierHeld),
        (true,  true,  String?.some("com.example.foo"),      .skipModifierHeld),
        (true,  true,  String?.some("com.apple.finder"),     .skipModifierHeld),
        (true,  false, String?.none,                         .paste),
        (true,  false, String?.some("com.example.safe"),     .paste),
        (true,  false, String?.some("com.apple.finder"),     .skipUnsafeTarget(bundleID: "com.apple.finder")),
        (true,  false, String?.some("com.agilebits.onepassword8"), .skipUnsafeTarget(bundleID: "com.agilebits.onepassword8")),
    ])
    func decide(enabled: Bool, shiftHeld: Bool, bundleID: String?, expected: AutoPasteDecision) {
        #expect(AutoPasteGuard.decide(enabled: enabled, shiftHeld: shiftHeld, frontmostBundleID: bundleID) == expected)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AutoPasteGuardTests`
Expected: compile error — `AutoPasteDecision` / `AutoPasteGuard` do not exist.

- [ ] **Step 3: Create `AutoPasteDecision.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcUI/AutoPasteDecision.swift`:

```swift
import Foundation

/// Outcome of the auto-paste policy check. The caller inspects this to
/// decide whether to paste and, if not, which kind of skip happened —
/// which drives the menu-bar flash style.
public enum AutoPasteDecision: Equatable, Sendable {
    case paste
    case skipDisabled
    case skipModifierHeld
    case skipUnsafeTarget(bundleID: String)
}

/// Pure decision function for auto-paste-on-stop. Precedence:
///
/// 1. `!enabled`      → `.skipDisabled`
/// 2. `shiftHeld`     → `.skipModifierHeld` (user-initiated override)
/// 3. deny-list hit   → `.skipUnsafeTarget`
/// 4. otherwise       → `.paste`
///
/// See spec §3.1 for the full matrix.
public enum AutoPasteGuard {
    public static func decide(
        enabled: Bool,
        shiftHeld: Bool,
        frontmostBundleID: String?
    ) -> AutoPasteDecision {
        if !enabled { return .skipDisabled }
        if shiftHeld { return .skipModifierHeld }
        if let id = frontmostBundleID, PasteDenyList.isDenied(id) {
            return .skipUnsafeTarget(bundleID: id)
        }
        return .paste
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AutoPasteGuardTests`
Expected: all 10 matrix cases pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/AutoPasteDecision.swift Tests/HarcUITests/AutoPasteGuardTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): AutoPasteDecision + pure AutoPasteGuard.decide

Enum with four cases (paste, skipDisabled, skipModifierHeld,
skipUnsafeTarget) and a pure decision function. Precedence: disabled
> shift-held > deny-list > paste. Fully unit-tested via 10-case matrix.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `HarcPreferences.autoPasteEnabled`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/HarcPreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside the `struct HarcPreferencesTests` in `/Users/jlane/GitHub/Harc/Tests/HarcUITests/HarcPreferencesTests.swift`:

```swift
    @Test("autoPasteEnabled defaults to true when UserDefaults has no key")
    func autoPasteEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
        let prefs = HarcPreferences()
        #expect(prefs.autoPasteEnabled == true)
    }

    @Test("autoPasteEnabled persists and round-trips through UserDefaults")
    func autoPasteEnabledPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
        let prefs = HarcPreferences()
        prefs.autoPasteEnabled = false
        let reloaded = HarcPreferences()
        #expect(reloaded.autoPasteEnabled == false)
        // Restore default for subsequent tests.
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HarcPreferencesTests`
Expected: compile error — `HarcPreferences` has no `autoPasteEnabled`.

- [ ] **Step 3: Add `autoPasteEnabled` to `HarcPreferences`**

In `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`:

**(a)** Add a new constant to the private `Key` enum (at the top of the class, around line 11). Insert after the existing `meetingAppEnabled` constant:

```swift
        static let autoPasteEnabled = "harc.autoPasteEnabled"
```

**(b)** Add a new `@Published` property. Insert after the existing `meetingAppEnabled` property (around line 44):

```swift
    @Published public var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: Key.autoPasteEnabled) }
    }
```

**(c)** Initialize the property inside `init()`. Insert after the `meetingAppEnabled` initialization block (around line 72, inside the `init()` method, after the `else { self.meetingAppEnabled = [ ... ] }` block):

```swift
        self.autoPasteEnabled = defaults.object(forKey: Key.autoPasteEnabled) as? Bool ?? true
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HarcPreferencesTests`
Expected: all `HarcPreferencesTests` pass, including the two new cases.

- [ ] **Step 5: Run the full test suite to confirm nothing regressed**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcUI/HarcPreferences.swift Tests/HarcUITests/HarcPreferencesTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): HarcPreferences.autoPasteEnabled (default true)

New @Published Bool persisted to UserDefaults under harc.autoPasteEnabled.
Default is true — matches today's unconditional paste behavior for users
who don't touch Settings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `FrontmostAppPaster.frontmostBundleID()`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/FrontmostAppPaster.swift`

No test — this is a one-liner wrapper over AppKit. Manual smoke happens in Task 9.

- [ ] **Step 1: Add the helper**

In `/Users/jlane/GitHub/Harc/Sources/HarcUI/FrontmostAppPaster.swift`, append inside the `FrontmostAppPaster` enum (after the existing `copyOnly(_:)` function):

```swift
    /// Bundle ID of the current frontmost application. Call this BEFORE any
    /// Harc window has hidden — otherwise the reading reflects whatever app
    /// receives focus after `NSApp.hide(nil)`.
    @MainActor
    public static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcUI/FrontmostAppPaster.swift
git commit -m "$(cat <<'EOF'
feat(ui): FrontmostAppPaster.frontmostBundleID()

Thin wrapper over NSWorkspace.shared.frontmostApplication.bundleIdentifier
for callers that need to capture the paste target *before* Harc hides.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `MenuBarFlash`

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/MenuBarFlash.swift`

No unit test — this is a timer-driven AppKit side-effect. Manual smoke in Task 9.

- [ ] **Step 1: Create `MenuBarFlash.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcUI/MenuBarFlash.swift`:

```swift
import AppKit

/// Briefly swaps a status-item's icon for a symbol that indicates the
/// outcome of an auto-paste attempt, then calls a caller-supplied
/// `restore` closure to return to whatever idle/recording icon was
/// previously displayed.
///
/// All methods require @MainActor. The helper is stateless beyond the
/// Task that schedules the restore; overlapping flashes simply restore
/// to the last-known state via the most recent `restore` closure.
@MainActor
public final class MenuBarFlash {
    public init() {}

    /// Green checkmark — paste succeeded.
    public func flashSuccess(
        on item: NSStatusItem,
        duration: TimeInterval = 0.8,
        restore: @escaping @MainActor () -> Void
    ) {
        flash(
            item,
            symbol: "checkmark.circle.fill",
            tint: .systemGreen,
            tooltip: nil,
            duration: duration,
            restore: restore
        )
    }

    /// Red exclamation — paste attempt failed (accessibility denied, etc.).
    public func flashFailure(
        on item: NSStatusItem,
        duration: TimeInterval = 0.8,
        restore: @escaping @MainActor () -> Void
    ) {
        flash(
            item,
            symbol: "exclamationmark.circle.fill",
            tint: .systemRed,
            tooltip: nil,
            duration: duration,
            restore: restore
        )
    }

    /// Amber raised hand — paste intentionally skipped (unsafe target,
    /// deny-list match). Longer duration + tooltip gives the user time to
    /// read why.
    public func flashSkipped(
        on item: NSStatusItem,
        tooltip: String,
        duration: TimeInterval = 1.2,
        restore: @escaping @MainActor () -> Void
    ) {
        flash(
            item,
            symbol: "hand.raised.fill",
            tint: .systemOrange,
            tooltip: tooltip,
            duration: duration,
            restore: restore
        )
    }

    private func flash(
        _ item: NSStatusItem,
        symbol: String,
        tint: NSColor,
        tooltip: String?,
        duration: TimeInterval,
        restore: @escaping @MainActor () -> Void
    ) {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = tint
        button.toolTip = tooltip
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            button.toolTip = nil
            button.contentTintColor = nil
            restore()
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Build the Xcode project**

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds (ignore the standard multi-destination warning).

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/MenuBarFlash.swift
git commit -m "$(cat <<'EOF'
feat(ui): MenuBarFlash — success/failure/skipped status-item icon flash

@MainActor helper that swaps the NSStatusItem button image for 0.8–1.2s
(symbol + tint + optional tooltip), then runs a caller-supplied restore
closure. Consumed by AppDelegate's auto-paste path (next task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `RecordingSettingsView` — Auto-paste section

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/RecordingSettingsView.swift`

No unit test — SwiftUI Form layout. Manual smoke verifies the toggle renders and flips `prefs.autoPasteEnabled`.

- [ ] **Step 1: Locate the insertion point**

In `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/RecordingSettingsView.swift`, the `Form { }` body currently contains sections in this order: Destination → Chunk duration → Global hotkey → Meeting detection → Monitored apps. Insert the new **Auto-paste** section between **Chunk duration** and **Global hotkey**.

- [ ] **Step 2: Add the new Section**

Find the existing `Section { KeyboardShortcuts.Recorder("Toggle recording:", name: .toggleRecording) } header: { Text("Global hotkey") }` block (around line 48). Insert the following BEFORE it:

```swift
            Section {
                Toggle("Auto-paste on stop", isOn: $prefs.autoPasteEnabled)
                    .tint(HarcDesign.primary)
            } header: {
                Text("Auto-paste")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("When recording stops, the prompt-formatted transcript is pasted into the frontmost app.")
                    Text("Hold ⇧ while clicking Stop, or ⌥-click the menu-bar icon, to skip for one recording. Paste is always skipped for password managers, Finder, and meeting apps.")
                }
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/Settings/RecordingSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(ui): Settings — Auto-paste on stop toggle

New Section above Global hotkey. Toggle binds to prefs.autoPasteEnabled.
Footer documents the Shift + ⌥-click escape hatches and the always-deny
targets (password managers, Finder, meeting apps).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `AppDelegate` — `runAutoPaste` + accessibility modal + wire into `stopRecording`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

Core wiring task. Replaces the unconditional paste block at lines 242–244 with the guarded flow, adds two new `AppDelegate` properties, two private helpers, and the `runAutoPaste(for:)` method.

- [ ] **Step 1: Add new stored properties**

In `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`, add two new stored properties near the existing `private var menuBarTicker: Timer?` declaration (around line 29):

```swift
    private let menuBarFlash = MenuBarFlash()
    private var accessibilityPromptShown = false
```

- [ ] **Step 2: Restructure `stopRecording()` so `rec` is visible at the paste site**

In `stopRecording()` (around lines 213–251), the `Recording` value is currently constructed inside `if let store = self.store`. Move the construction above the `if let store` block so it's visible in the outer scope:

Find (around line 215):

```swift
    private func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stop()
            state.markStopped(wavURL: result.wavURL, txtURL: result.txtURL, jsonURL: result.jsonURL)
            let transcriptText = result.txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            if let store = self.store {
                let startedAt = result.wavURL.startedAtFromHarcPath() ?? Date()
                let rec = Recording(
                    wavPath: result.wavURL.path,
                    txtPath: result.txtURL?.path,
                    jsonPath: result.jsonURL?.path,
                    startedAt: startedAt,
                    endedAt: Date(),
                    transcriptText: transcriptText
                )
                _ = try? await store.upsert(rec)
            }
            if let transcriptText, let store = self.store {
                Task.detached { [store] in
                    let entities = TitleSuggester.extractEntities(from: transcriptText)
                    let suggestion = entities.isEmpty ? nil : Array(entities.prefix(2)).joined(separator: ", ")
                    guard suggestion != nil || !entities.isEmpty else { return }
                    guard let persisted = try? await store.fetchByWavPath(result.wavURL.path),
                          let id = persisted.id else { return }
                    if let suggestion { try? await store.updateSuggestedTitle(id: id, title: suggestion) }
                    if !entities.isEmpty { try? await store.updateTags(id: id, tags: entities) }
                }
            }
            if let text = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                try? FrontmostAppPaster.copyAndPaste(text)
            }
        } catch {
            presentError(error)
        }
        previewTask?.cancel()
        previewTask = nil
```

Replace with:

```swift
    private func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stop()
            state.markStopped(wavURL: result.wavURL, txtURL: result.txtURL, jsonURL: result.jsonURL)
            let transcriptText = result.txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let startedAt = result.wavURL.startedAtFromHarcPath() ?? Date()
            let rec = Recording(
                wavPath: result.wavURL.path,
                txtPath: result.txtURL?.path,
                jsonPath: result.jsonURL?.path,
                startedAt: startedAt,
                endedAt: Date(),
                transcriptText: transcriptText
            )
            if let store = self.store {
                _ = try? await store.upsert(rec)
            }
            if let transcriptText, let store = self.store {
                Task.detached { [store] in
                    let entities = TitleSuggester.extractEntities(from: transcriptText)
                    let suggestion = entities.isEmpty ? nil : Array(entities.prefix(2)).joined(separator: ", ")
                    guard suggestion != nil || !entities.isEmpty else { return }
                    guard let persisted = try? await store.fetchByWavPath(result.wavURL.path),
                          let id = persisted.id else { return }
                    if let suggestion { try? await store.updateSuggestedTitle(id: id, title: suggestion) }
                    if !entities.isEmpty { try? await store.updateTags(id: id, tags: entities) }
                }
            }
            runAutoPaste(for: rec)
        } catch {
            presentError(error)
        }
        previewTask?.cancel()
        previewTask = nil
```

The diff is: `rec` now lives in the outer scope, the store upsert becomes `if let store`-guarded, and the bottom `if let text = transcriptText...; try? FrontmostAppPaster.copyAndPaste(text)` is replaced by `runAutoPaste(for: rec)`.

- [ ] **Step 3: Add `runAutoPaste(for:)` and its helpers**

Add these three methods to `AppDelegate`. Place them near the existing `presentError(_:)` helper (around line 440):

```swift
    @MainActor
    private func runAutoPaste(for rec: Recording) {
        let decision = AutoPasteGuard.decide(
            enabled: prefs.autoPasteEnabled,
            shiftHeld: NSEvent.modifierFlags.contains(.shift),
            frontmostBundleID: FrontmostAppPaster.frontmostBundleID()
        )

        guard let statusItem else { return }
        let restore: @MainActor () -> Void = { [weak self] in
            self?.updateMenuBarIcon(recording: false)
        }

        switch decision {
        case .skipDisabled, .skipModifierHeld:
            return
        case .skipUnsafeTarget(let id):
            menuBarFlash.flashSkipped(
                on: statusItem,
                tooltip: "Auto-paste skipped — \(appDisplayName(for: id))",
                restore: restore
            )
        case .paste:
            let blob = ExportService.promptString(for: rec)
            do {
                try FrontmostAppPaster.copyAndPaste(blob)
                menuBarFlash.flashSuccess(on: statusItem, restore: restore)
            } catch FrontmostAppPaster.PasteError.accessibilityDenied {
                menuBarFlash.flashFailure(on: statusItem, restore: restore)
                if !accessibilityPromptShown {
                    accessibilityPromptShown = true
                    presentAccessibilityPrompt()
                }
            } catch {
                menuBarFlash.flashFailure(on: statusItem, restore: restore)
            }
        }
    }

    @MainActor
    private func presentAccessibilityPrompt() {
        let alert = NSAlert()
        alert.messageText = "Harc needs Accessibility permission"
        alert.informativeText = "Auto-paste synthesises ⌘V into the frontmost app. macOS requires Accessibility permission for that. Your transcript is still on the clipboard — you can paste it manually with ⌘V."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
```

- [ ] **Step 4: Import `HarcExport`**

`AppDelegate` uses `ExportService.promptString(for:)`. Check the `import` block at the top of `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`. If `import HarcExport` is not already there, add it below `import HarcUI`:

```swift
import HarcAudio
import HarcClient
import HarcExport
import HarcMeetingDetect
import HarcStore
import HarcUI
import KeyboardShortcuts
```

(Alphabetical among Harc modules.)

- [ ] **Step 5: Build**

Run: `swift build`
Expected: build succeeds.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(app): guarded auto-paste on stop

Replaces the unconditional FrontmostAppPaster.copyAndPaste(text) with
runAutoPaste(for:): AutoPasteGuard decision, ExportService.promptString
content, MenuBarFlash feedback, and a one-shot Accessibility-denied
modal. Lifts `rec` out of the store-conditional block so it's visible
at the paste site.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: ⌥-click status-item escape hatch

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

Adds a secondary escape hatch: ⌥-clicking the menu-bar icon while a recording is active stops it without auto-pasting. Mechanism: a transient `pendingSkipPaste` flag that `runAutoPaste` reads and clears.

- [ ] **Step 1: Add the transient flag**

In `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`, next to the `accessibilityPromptShown` property you added in Task 7, add:

```swift
    private var pendingSkipPaste = false
```

- [ ] **Step 2: Extend `handleStatusItemClick(_:)`**

Find the existing `handleStatusItemClick(_:)` (around line 126):

```swift
    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu()
        } else {
            togglePopover(sender)
        }
    }
```

Replace with:

```swift
    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu()
            return
        }
        // ⌥-left-click while recording → stop without auto-paste.
        if state.isRecording,
           NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            pendingSkipPaste = true
            Task { await stopRecording() }
            return
        }
        togglePopover(sender)
    }
```

- [ ] **Step 3: Have `runAutoPaste` honour the flag**

In the `runAutoPaste(for:)` method you added in Task 7, modify the first few lines to OR `pendingSkipPaste` into the `shiftHeld` argument (and clear it regardless of outcome):

Find:

```swift
    @MainActor
    private func runAutoPaste(for rec: Recording) {
        let decision = AutoPasteGuard.decide(
            enabled: prefs.autoPasteEnabled,
            shiftHeld: NSEvent.modifierFlags.contains(.shift),
            frontmostBundleID: FrontmostAppPaster.frontmostBundleID()
        )
```

Replace with:

```swift
    @MainActor
    private func runAutoPaste(for rec: Recording) {
        let shiftOrOptClick = NSEvent.modifierFlags.contains(.shift) || pendingSkipPaste
        pendingSkipPaste = false
        let decision = AutoPasteGuard.decide(
            enabled: prefs.autoPasteEnabled,
            shiftHeld: shiftOrOptClick,
            frontmostBundleID: FrontmostAppPaster.frontmostBundleID()
        )
```

The flag folds into the same `.skipModifierHeld` path in `AutoPasteGuard`, so no new decision case is needed. `pendingSkipPaste` is cleared immediately to prevent accidental carry-over to a subsequent normal stop.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: build succeeds.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(app): ⌥-click status item to stop without auto-paste

Secondary escape hatch to match Shift-while-stopping. handleStatusItemClick
now intercepts ⌥-left-click while recording, sets a transient
pendingSkipPaste flag, and routes through toggleRecording → stopRecording.
runAutoPaste ORs the flag into the shiftHeld argument and clears it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: End-to-end manual verification

**Files:** none.

- [ ] **Step 1: Full test suite green**

Run: `swift test`
Expected: 0 failures. New tests (PasteDenyList, AutoPasteGuard, HarcPreferences auto-paste) all pass alongside existing suites.

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 3: Smoke — happy path**

Launch Harc. Open Settings → Recording → confirm the new **Auto-paste** section exists with a toggle that starts in the ON position.

With the toggle ON, open TextEdit and click into the main text area. Start a recording via the global hotkey, say a few seconds of audio, stop via the hotkey. Expect:

- Menu-bar icon briefly turns **green with a checkmark** (~0.8s), then returns to the default template icon.
- TextEdit's cursor position fills with the prompt-formatted blob (YAML front-matter + speaker-labelled body).

- [ ] **Step 4: Smoke — toggle OFF**

Flip **Auto-paste on stop** to OFF. Start+stop another short recording with TextEdit frontmost. Expect:

- No menu-bar flash.
- Nothing pastes into TextEdit.
- The clipboard still holds the prompt-formatted blob — paste manually with ⌘V and confirm.

Flip the toggle back ON for the rest of the smoke steps.

- [ ] **Step 5: Smoke — deny-list target**

Click into the Finder window. Start+stop a recording with Finder frontmost. Expect:

- Menu-bar icon briefly turns **amber with a raised-hand** (~1.2s) and its tooltip reads "Auto-paste skipped — Finder".
- Nothing pastes anywhere.

- [ ] **Step 6: Smoke — Shift escape hatch (popover path)**

Click the menu-bar icon to open the popover; hit Record. While recording, hold **Shift** and click the Stop button in the popover. Expect:

- No flash.
- No paste.
- Recording stops normally; the transcript is on the clipboard.

(If the primary hotkey path works with `KeyboardShortcuts` + Shift — unlikely — also verify by holding Shift while firing the stop hotkey. If it does not, this is expected; use the ⌥-click path in Step 7.)

- [ ] **Step 7: Smoke — ⌥-click escape hatch**

Start a recording. Hold **Option** and left-click the menu-bar icon. Expect:

- Recording stops.
- No flash, no paste.

- [ ] **Step 8: Smoke — Accessibility denied**

Revoke Harc's Accessibility permission in System Settings → Privacy & Security → Accessibility. Click into TextEdit. Start+stop a short recording with the toggle ON. Expect:

- Menu-bar icon briefly turns **red with an exclamation mark**.
- A modal appears titled "Harc needs Accessibility permission" with buttons "Open System Settings" and "Later".
- Dismiss the modal. Start+stop another recording with permission still revoked. Expect: red flash only, no modal (one-shot-per-session).

Re-grant Accessibility, quit and relaunch Harc, repeat to confirm the modal shows again on the first denied paste of the new session.

- [ ] **Step 9: No new warnings**

Run: `swift build 2>&1 | grep -E 'warning:' || true`
Expected: no new warnings introduced by this feature.

- [ ] **Step 10: Final tidy**

If anything surfaced during smoke that should live in the spec (e.g., a behavior clarification), update `docs/superpowers/specs/2026-04-19-auto-paste-design.md` and commit separately. Otherwise no further commits.

---

## Self-review notes

- **Spec coverage.** Every §3 behavioral rule maps to a task: §3 steps 1–3 → T7 `runAutoPaste`. §3.1 matrix → T2 tests. §3.2 Shift-precedence → T2 (order of checks). §3.3 one-shot modal → T7 `accessibilityPromptShown` flag + `presentAccessibilityPrompt`. §4 deny-list → T1 `PasteDenyList.bundleIDs`. §5.1 `PasteDenyList` → T1; `AutoPasteDecision`/`AutoPasteGuard` → T2; `MenuBarFlash` → T5. §5.2 pref + paster helper + settings view + AppDelegate wiring → T3 + T4 + T6 + T7. §5.3 ⌥-click → T8. §7 tests → T1 (deny-list), T2 (guard matrix), T3 (prefs round-trip), T9 (manual). §8 open decisions explicitly OK as-is.
- **Type consistency.** `AutoPasteDecision.skipUnsafeTarget(bundleID: String)` uses the labeled-argument form everywhere — T2 enum, T2 test matrix, T7 `switch` pattern match, T8 unchanged. `MenuBarFlash` signatures match across T5 and T7 call sites. `FrontmostAppPaster.frontmostBundleID()` is `@MainActor public static func -> String?` in T4 and called as such in T7. `HarcPreferences.autoPasteEnabled` is `Bool` in T3 and bound via `$prefs.autoPasteEnabled` in T6.
- **Commit cadence.** One commit per task. T7's restructure (lifting `rec`) is bundled with the new paste path — they're part of the same semantic change and make one atomic commit.
- **Manual-smoke scope.** Limited to behaviors this plan changes. Does not exercise recording, transcription, or clipboard-history flows from other features.
- **⌥-click hotkey caveat.** T8's ⌥-click path is a behavior add, not a replacement — the Shift-modifier read in T7 still handles popover-click stops. Users who stop via the hotkey and want the escape hatch will discover the ⌥-click alternative via the Settings footer text (T6).
