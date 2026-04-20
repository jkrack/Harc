# Auto-paste on Stop Design Doc

**Feature:** Promote auto-paste-on-stop from an unconditional side effect to a user-controlled, guarded, visibly-confirmed behavior. Uses the prompt-formatted blob from the Copy-for-Prompt feature as its content source.
**Date:** 2026-04-19
**Status:** draft — ready for implementation

---

## 1. Problem & user story

Today `AppDelegate.stopRecording()` unconditionally writes the raw transcript to the clipboard and synthesizes Cmd-V into whatever app is frontmost. It's silent (`try?`), has no toggle, and doesn't check what app it's about to paste into. Three gaps:

- **No opt-out.** The user occasionally stops a recording with a sensitive app frontmost (Slack DM, a password field) or simply doesn't want the paste. There's no way to suppress it without opening code.
- **No feedback.** Successes look the same as silent failures. When the Accessibility permission is revoked, pastes stop working with no indication.
- **No target safety.** Auto-paste into `loginwindow`, Finder, or a password manager can accidentally leak an hour of transcript. The user-initiated Paste button in the Library has the same property, but the auto-paste-on-stop path is more dangerous because the user isn't watching the clipboard at that moment.

**User story (happy path).** "I stop a meeting via the global hotkey. My menu-bar icon flashes green for half a second; my Claude tab — which was frontmost — fills with the prompt-formatted transcript. I tab back and paste my own question."

**User story (guarded).** "I stop a recording and Finder happens to be frontmost. The menu-bar icon flashes amber briefly. Nothing pastes. I open Claude, switch to it, hit Cmd-V — the transcript is still on my clipboard from the Copy-for-Prompt default."

**User story (opt-out).** "I hold Shift while triggering the stop hotkey. Nothing pastes, no flash, no fuss. The transcript is on the clipboard; I decide where it goes."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A new boolean preference `HarcPreferences.autoPasteEnabled` (default `true`), with a Settings toggle in `RecordingSettingsView`.
- A pure `AutoPasteGuard.decide(...)` that returns one of four decisions: `paste`, `skipDisabled`, `skipModifierHeld`, `skipUnsafeTarget(bundleID:)`.
- A compile-time `PasteDenyList` seed set of bundle IDs that are never safe auto-paste targets.
- A `MenuBarFlash` helper that briefly swaps the status-item icon for a success / failure / skipped symbol and restores it after a short duration.
- Accessibility-denied error path: red flash + a one-shot-per-session modal linking to System Settings → Privacy & Security → Accessibility.
- Content source for the paste: `ExportService.promptString(for: rec)` (produced by the Copy-for-Prompt feature already on main).
- Shift-to-skip via `NSEvent.modifierFlags.contains(.shift)` read at the top of `stopRecording()`; fall back to ⌥-click on the menu-bar icon for "Stop without paste" if the `KeyboardShortcuts` library strips the Shift modifier before firing (verify during implementation).

**Out of scope / non-goals (v1):**

- **User-editable deny-list or allow-list UI.** Seed list is hard-coded. Revisit if the user hits a false-positive they want on the deny-list, or a recurring false-negative they'd add to an allow-list.
- **Length confirmation.** "Transcript is 47 minutes — paste anyway?" dialogs add a click to the happy path for exactly the long recordings the feature exists to serve.
- **Per-recording auto-paste override for historical recordings.** The Library's Paste button (`TranscriptionDetailView`) remains a manual, unguarded, unconditional action. It is user-initiated into a known context and uses the same `FrontmostAppPaster.copyAndPaste` primitive.
- **A second global hotkey for "stop without paste."** ⌥-click on the menu-bar icon is the secondary escape hatch if the Shift-modifier read doesn't work through `KeyboardShortcuts`.
- **Custom toast / SwiftUI overlay subsystem.** Menu-bar flash is the user-visible surface; no floating panels, no HUD.
- **Paste history / outcome logging.** No persistence of "paste succeeded to <bundleID> at <time>."
- **Changing `FrontmostAppPaster.copyAndPaste`'s core behavior.** The primitive is unchanged; this feature adds a guard layer around its call site and a feedback layer around its result.

---

## 3. Behavioral specification

On recording-stop, after `session.stop()` succeeds and the `Recording` row is upserted:

1. **Capture context** (order matters — read *before* any `NSApp.hide(nil)` inside the paster):
   - `enabled = prefs.autoPasteEnabled`
   - `shiftHeld = NSEvent.modifierFlags.contains(.shift)`
   - `frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier`

2. **Decide** via `AutoPasteGuard.decide(enabled:shiftHeld:frontmostBundleID:)`.

3. **Act** on the decision:

   | Decision | Action |
   |---|---|
   | `.paste` | `FrontmostAppPaster.copyAndPaste(ExportService.promptString(for: rec))`; on success → `MenuBarFlash.flashSuccess`; on `.accessibilityDenied` → `MenuBarFlash.flashFailure` + one-shot modal; on other throws → `MenuBarFlash.flashFailure` silently |
   | `.skipDisabled` | nothing — no flash, silent |
   | `.skipModifierHeld` | nothing — silent (user pressed Shift deliberately) |
   | `.skipUnsafeTarget(let id)` | `MenuBarFlash.flashSkipped(tooltip: "Auto-paste skipped — \(appDisplayName(for: id))")` |

The clipboard ALWAYS holds the prompt-formatted blob at the end of step 3, regardless of decision. Whether the keystroke fired into the frontmost app is the only thing that varies. This preserves the Copy-for-Prompt promise that Cmd-V in any app yields the transcript.

### 3.1 Decision matrix

| `enabled` | `shiftHeld` | `frontmostBundleID` | Decision |
|---|---|---|---|
| `false` | any | any | `.skipDisabled` |
| `true` | `true` | any | `.skipModifierHeld` |
| `true` | `false` | `nil` | `.paste` (no frontmost app = no obvious unsafe target; let the paster's own `noFrontmostApp` error surface if it matters) |
| `true` | `false` | in deny-list | `.skipUnsafeTarget(id)` |
| `true` | `false` | not in deny-list | `.paste` |

The `nil` bundle-ID case is intentionally permissive. It's rare (usually only during launch/quit transitions), and the paster itself will throw `.noFrontmostApp` if the keystroke has nowhere to land — the resulting red flash is adequate signaling.

### 3.2 Shift precedence

Shift precedence is explicit: `skipModifierHeld` wins over `skipUnsafeTarget`. If the user held Shift while stopping, we don't even look at the frontmost app — they said "don't paste" and we trust them. The alternative (check deny-list first) would sometimes announce "I would have skipped anyway because the target was unsafe," which is noise.

### 3.3 Accessibility-denied one-shot modal

Rationale: the first time a user hits this, they need to know how to fix it. On every subsequent stop where Accessibility is still denied, a modal would be harassment. So:

- `AppDelegate` owns `private var accessibilityPromptShown = false` (resets on app relaunch).
- Only the first `PasteError.accessibilityDenied` per app session shows the modal; subsequent ones do red flash only.
- Modal buttons: "Open System Settings" (opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` via `NSWorkspace.shared.open(_:)`) and "Later" (close).

---

## 4. Paste deny-list

```
com.apple.loginwindow                 Lock screen / login
com.apple.finder                      Finder (Finder paths vs. text fields are ambiguous; skip)
com.apple.systempreferences           System Settings
com.apple.ScreenSaver.Engine          Screensaver
com.agilebits.onepassword7
com.agilebits.onepassword8
com.bitwarden.desktop
com.lastpass.LastPass
org.keepassxc.keepassxc
us.zoom.xos                           Zoom (a 1-hour transcript in the meeting chat is a disaster)
com.microsoft.teams2                  Teams (same)
```

Stored as a `Set<String>` in `PasteDenyList.bundleIDs`. `PasteDenyList.isDenied(_:)` wraps `bundleIDs.contains(_:)` so the call site reads cleanly even when the ID is optional:

```swift
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

A nil bundle-ID returns `false` so the guard falls through to `.paste` in the `nil` row of §3.1.

Future change surface: if a user-editable list is added later, swap the seed set for a `UserDefaults`-backed `[String]` and keep the callers unchanged. That's a v2 spec.

---

## 5. Code architecture

All changes contained to **HarcUI** (types, views, paster extension) + **HarcApp** (wiring). No new SwiftPM target. No new third-party dependencies.

### 5.1 New files

**`Sources/HarcUI/PasteDenyList.swift`** — the seed set + `isDenied` predicate (shown above).

**`Sources/HarcUI/AutoPasteDecision.swift`**:

```swift
public enum AutoPasteDecision: Equatable, Sendable {
    case paste
    case skipDisabled
    case skipModifierHeld
    case skipUnsafeTarget(bundleID: String)
}

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

Pure, synchronous, trivially unit-tested.

**`Sources/HarcUI/MenuBarFlash.swift`**:

```swift
@MainActor
public final class MenuBarFlash {
    public init() {}

    /// Briefly swap the status item's icon to indicate the paste outcome.
    /// `restore` runs after `duration` to return the status item to its
    /// caller-determined idle/recording state.
    public func flashSuccess(
        on item: NSStatusItem,
        duration: TimeInterval = 0.8,
        restore: @escaping @MainActor () -> Void
    ) { flash(item, symbol: "checkmark.circle.fill", tint: .systemGreen, tooltip: nil, duration: duration, restore: restore) }

    public func flashFailure(
        on item: NSStatusItem,
        duration: TimeInterval = 0.8,
        restore: @escaping @MainActor () -> Void
    ) { flash(item, symbol: "exclamationmark.circle.fill", tint: .systemRed, tooltip: nil, duration: duration, restore: restore) }

    public func flashSkipped(
        on item: NSStatusItem,
        tooltip: String,
        duration: TimeInterval = 1.2,
        restore: @escaping @MainActor () -> Void
    ) { flash(item, symbol: "hand.raised.fill", tint: .systemOrange, tooltip: tooltip, duration: duration, restore: restore) }

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

The `restore` closure is how `AppDelegate` says "after the flash ends, go back to the idle / recording icon" — the flash helper itself doesn't know which state to return to. One instance suffices; multiple overlapping flashes restore to the last-known idle state (rare in practice).

### 5.2 Extended files

**`Sources/HarcUI/HarcPreferences.swift`** — one new `@Published` field:

```swift
@Published public var autoPasteEnabled: Bool {
    didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: Key.autoPasteEnabled) }
}
```

with a Key constant, default `true`, and initializer line:

```swift
self.autoPasteEnabled = defaults.object(forKey: Key.autoPasteEnabled) as? Bool ?? true
```

Matches the existing pattern for `diarize`, `meetingDetectionEnabled`, etc.

**`Sources/HarcUI/FrontmostAppPaster.swift`** — one small helper, no change to existing functions:

```swift
/// Bundle ID of the current frontmost application, captured *before* any
/// window-hide. Call this before invoking `copyAndPaste`.
@MainActor
public static func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}
```

The existing `copyAndPaste` and `synthesizeCmdV` implementations are unchanged. Their `PasteError` enum gains no new cases.

**`Sources/HarcUI/Settings/RecordingSettingsView.swift`** — a new `Section` below the chunk-duration section, above the global-hotkey section:

```swift
Section {
    Toggle("Auto-paste on stop", isOn: $prefs.autoPasteEnabled)
        .tint(HarcDesign.primary)
} header: {
    Text("Auto-paste")
} footer: {
    VStack(alignment: .leading, spacing: 2) {
        Text("When recording stops, the prompt-formatted transcript is pasted into the frontmost app.")
        Text("Hold ⇧ or ⌥-click the menu-bar icon to skip for one recording. Paste is skipped automatically for password managers, Finder, and meeting apps.")
    }
    .font(HarcDesign.Font.bodySm)
    .foregroundStyle(Color.harcOnSurfaceVariant)
}
```

**`HarcApp/AppDelegate.swift`** — replaces the unconditional paste block (currently lines 242–244) with the guarded path, plus two new members:

```swift
// Added as stored properties on AppDelegate:
private let menuBarFlash = MenuBarFlash()
private var accessibilityPromptShown = false
```

New helper (private, on `AppDelegate`):

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
```

Wired in at the end of the `stopRecording()` do-block (replacing the existing `if let text = ...; try? FrontmostAppPaster.copyAndPaste(text)` block):

```swift
runAutoPaste(for: rec)
```

`rec` is the `Recording` value already constructed a few lines earlier for the `store.upsert(rec)` call — reuse the same local. That means moving the `rec` construction out of the `if let store = self.store` block so it's always available, or inlining the construction in both call sites. The plan will pick the smaller change.

Additional helpers on `AppDelegate`:

```swift
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
    // Best-effort lookup; falls back to the bundle ID verbatim.
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return bundleID }
    return FileManager.default.displayName(atPath: url.path)
}
```

### 5.3 ⌥-click "stop without paste" (secondary escape hatch)

The menu-bar icon's left-click currently calls `handleStatusItemClick`. Extend that handler (or add a new one) to inspect `NSApp.currentEvent?.modifierFlags`. If `.option` is present and recording is active, treat the click as "stop without paste" — mark a transient flag `pendingSkipPaste = true`, then toggle stop as normal. `runAutoPaste` checks the flag and clears it: if set, returns immediately.

The `NSEvent.modifierFlags` read in `runAutoPaste` is the primary path for the hotkey; the flag is the secondary path for menu-bar interaction. One is for keyboard users, the other for mouse users. Plan will decide whether the `pendingSkipPaste` flag is needed (verify primary-path reliability first).

---

## 6. Data flow

```
stopRecording() @MainActor
  │
  ├─▶ session.stop()     → Result(wav/txt/json)
  ├─▶ store.upsert(rec)
  ├─▶ entity extraction (detached)
  │
  └─▶ runAutoPaste(for: rec)
        │
        ├─▶ read prefs.autoPasteEnabled
        ├─▶ read NSEvent.modifierFlags (.shift)
        ├─▶ read NSWorkspace.frontmostApplication.bundleIdentifier
        │
        └─▶ AutoPasteGuard.decide(...)        (pure)
               │
               ├─ .skipDisabled      → return
               ├─ .skipModifierHeld  → return
               ├─ .skipUnsafeTarget  → MenuBarFlash.flashSkipped(tooltip:)
               └─ .paste
                     │
                     ├─▶ ExportService.promptString(for: rec)  (pure)
                     ├─▶ FrontmostAppPaster.copyAndPaste(blob) (throws)
                     │
                     └─ switch outcome:
                           ├─ success              → flashSuccess
                           ├─ accessibilityDenied  → flashFailure + maybe modal
                           └─ other error          → flashFailure (silent)
```

Key properties:

- **Clipboard is always set** — every `.paste` branch writes to the pasteboard before attempting the keystroke. If the keystroke fails, the user can still ⌘V manually.
- **`AutoPasteGuard` is pure.** No AppKit, no pasteboard, no timer. Testable in isolation.
- **`MenuBarFlash` is the only visual side-effect surface.** `AppDelegate` owns the choice of which flash to call.
- **`restore` is caller-supplied.** The flash helper doesn't model recording vs. idle state.

---

## 7. Testing

### 7.1 `AutoPasteGuardTests` (Swift Testing, in `Tests/HarcUITests/`)

Table-driven across the §3.1 matrix:

```swift
@Test("decide — matrix", arguments: [
    (false, false, nil,                                   AutoPasteDecision.skipDisabled),
    (false, true,  nil,                                   .skipDisabled),
    (false, false, "com.example.foo",                     .skipDisabled),
    (true,  true,  nil,                                   .skipModifierHeld),
    (true,  true,  "com.example.foo",                     .skipModifierHeld),
    (true,  true,  "com.apple.finder",                    .skipModifierHeld),  // shift > deny
    (true,  false, nil,                                   .paste),
    (true,  false, "com.example.safe",                    .paste),
    (true,  false, "com.apple.finder",                    .skipUnsafeTarget(bundleID: "com.apple.finder")),
    (true,  false, "com.agilebits.onepassword8",          .skipUnsafeTarget(bundleID: "com.agilebits.onepassword8")),
])
func decide(enabled: Bool, shiftHeld: Bool, bundleID: String?, expected: AutoPasteDecision) {
    #expect(AutoPasteGuard.decide(enabled: enabled, shiftHeld: shiftHeld, frontmostBundleID: bundleID) == expected)
}
```

### 7.2 `PasteDenyListTests`

- Seed set contains `com.apple.loginwindow`, `com.agilebits.onepassword8`, `us.zoom.xos`, `com.microsoft.teams2` (the ones most likely to regress if someone rewrites the list).
- `isDenied(nil)` returns `false`.
- `isDenied("com.unknown.app")` returns `false`.
- `isDenied("com.apple.finder")` returns `true`.

### 7.3 `HarcPreferencesTests` (if the suite exists; otherwise skip to manual)

- Default `autoPasteEnabled` is `true` when UserDefaults has no key.
- Setting `false` persists and re-reads `false`.

### 7.4 Manual smoke

- Toggle OFF in Settings → start/stop a short recording. Expect: no flash, no paste, clipboard still holds prompt blob (from Copy-for-Prompt).
- Toggle ON, TextEdit frontmost → stop. Expect: green flash ~0.8s; TextEdit fills with the prompt blob.
- Toggle ON, Finder frontmost → stop. Expect: amber flash ~1.2s with tooltip "Auto-paste skipped — Finder". Nothing pastes.
- Toggle ON, hold Shift while hitting the stop hotkey → expect: no flash, no paste.
- Toggle ON, ⌥-click the red menu-bar icon → expect: no paste, no flash, recording stops normally.
- Toggle ON with Accessibility permission revoked → stop. Expect: red flash + modal "Harc needs Accessibility permission". Second stop with permission still revoked: red flash only, no modal.
- Toggle ON, stop with 1Password frontmost → amber flash, no paste.

---

## 8. Open decisions

- **Shift-modifier read-through.** The `KeyboardShortcuts` library (`sindresorhus/KeyboardShortcuts`) may or may not fire its callback when extra modifier keys are held above the registered chord. The spec assumes the primary path works; the plan's first task verifies it. If it doesn't, the ⌥-click-on-menu-bar path is the only mechanism and the Settings footer text is updated to reflect that.
- **Zoom / Teams on the deny-list.** Included because the primary dictation-and-paste flow is *into an LLM*, not into the meeting chat you were just on. A user who wants to paste into Zoom will opt out via Shift or the toggle. Revisit if that assumption is wrong.
- **Modal vs. notification for accessibility-denied.** Modal was chosen because the user is actively at the keyboard and just saw their paste fail — blocking is appropriate for a "first-run-permission" level event. A notification risks being missed. This is a one-shot-per-session interruption, not a recurring annoyance.
- **Flash durations.** 0.8s for green/red (positive/negative outcome), 1.2s for amber (skip-with-tooltip needs more time to read). Tune based on user feedback.

---

## 9. Sequencing with the rest of Tier 1

- **#3 Copy for Prompt** — ✅ landed on main; provides `ExportService.promptString` used here.
- **#1 Auto-paste (this spec)** — next.
- **#2 VAD gating** — independent. No interaction with this feature.
- **#4 Speaker renaming** — independent. Once landed, the paste content (via `promptString`) auto-upgrades from `Speaker 1 / Speaker 2` to real names. No work here.
